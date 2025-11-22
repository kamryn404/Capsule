import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'ffmpeg_service.dart';
import 'widgets/before_after.dart';
import 'widgets/media_controls.dart';

class VideoEditor extends StatefulWidget {
  final XFile file;
  final VoidCallback onClear;

  const VideoEditor({
    super.key,
    required this.file,
    required this.onClear,
  });

  @override
  State<VideoEditor> createState() => _VideoEditorState();
}

class _VideoEditorState extends State<VideoEditor> {
  VideoPlayerController? _originalController;
  VideoPlayerController? _compressedController;
  
  bool _isCompressing = false;
  bool _isPreviewing = false;
  double _bitrate = 5000; // kbps
  double _maxBitrate = 10000; // kbps
  String _outputFormat = 'av1'; // av1 or vp9
  double _scrubPosition = 0.0; // 0.0 to 1.0
  Duration _videoDuration = Duration.zero;
  double _progress = 0.0;
  bool _hasAv1Hardware = false;
  String? _originalSize;
  
  late FfmpegService _ffmpegService;
  
  // Optimization
  Timer? _debounceTimer;
  FfmpegTask? _currentPreviewTask;

  @override
  void initState() {
    super.initState();
    _ffmpegService = FfmpegServiceFactory.create();
    _ffmpegService.init();
    _initializeVideo();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _currentPreviewTask?.cancel();
    _originalController?.dispose();
    _compressedController?.dispose();
    super.dispose();
  }

  Future<void> _initializeVideo() async {
    final controller = VideoPlayerController.file(File(widget.file.path));
    await controller.initialize();
    
    // Check for hardware acceleration
    try {
      _hasAv1Hardware = await _ffmpegService.hasEncoder('av1_videotoolbox');
      if (_hasAv1Hardware) {
        debugPrint('AV1 Hardware Acceleration detected!');
      } else {
        debugPrint('AV1 Hardware Acceleration NOT detected.');
      }
    } catch (e) {
      debugPrint('Error checking encoders: $e');
    }

    // Get media info to set max bitrate
    try {
      final info = await _ffmpegService.getMediaInfo(widget.file.path);
      if (info.bitrate > 0) {
        setState(() {
          _maxBitrate = info.bitrate.toDouble();
          // Set default bitrate to 50% of original or 5000, whichever is lower
          _bitrate = (_maxBitrate * 0.5).clamp(10.0, 5000.0);
        });
      }
    } catch (e) {
      debugPrint('Error getting media info: $e');
    }

    final size = await File(widget.file.path).length();

    setState(() {
      _originalController = controller;
      _videoDuration = controller.value.duration;
      _originalSize = _formatBytes(size);
    });
    // Generate initial preview at start
    _generatePreview();
  }

  void _onScrubChanged(double value) {
    setState(() {
      _scrubPosition = value;
    });
    _debouncePreview();
  }

  void _onBitrateChanged(double value) {
    setState(() {
      _bitrate = value;
    });
    _debouncePreview();
  }

  void _debouncePreview() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _generatePreview();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Layer 1: Video Viewer
        Positioned.fill(
          child: Container(
            color: Colors.black12,
            child: _originalController != null && _originalController!.value.isInitialized
                ? BeforeAfter(
                    original: Center(
                      child: AspectRatio(
                        aspectRatio: _originalController!.value.aspectRatio,
                        child: VideoPlayer(_originalController!),
                      ),
                    ),
                    compressed: _compressedController != null && _compressedController!.value.isInitialized
                        ? Center(
                            child: AspectRatio(
                              aspectRatio: _compressedController!.value.aspectRatio,
                              child: VideoPlayer(_compressedController!),
                            ),
                          )
                        : null,
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
        ),

        // Layer 2: Floating Controls
        Positioned(
          right: 20,
          bottom: 20,
          child: MediaControls(
            scrubPosition: _scrubPosition,
            duration: _videoDuration,
            outputFormat: _outputFormat,
            bitrate: _bitrate,
            maxBitrate: _maxBitrate,
            isCompressing: _isCompressing,
            isPreviewing: _isPreviewing,
            progress: _progress,
            originalSize: _originalSize,
            estimatedSize: _estimateSize(),
            hasAv1Hardware: _hasAv1Hardware,
            onScrubChanged: _onScrubChanged,
            onScrubEnd: (value) {
              _debounceTimer?.cancel();
              _generatePreview();
            },
            onFormatChanged: (newValue) {
              if (newValue != null) {
                setState(() {
                  _outputFormat = newValue;
                });
                _generatePreview();
              }
            },
            onBitrateChanged: _onBitrateChanged,
            onBitrateEnd: (value) {
              _debounceTimer?.cancel();
              _generatePreview();
            },
            onClear: widget.onClear,
            onSave: _saveVideo,
            formatItems: [
              DropdownMenuItem(
                value: 'av1',
                child: Text('AV1 (MP4)${_hasAv1Hardware ? " [HW]" : ""}'),
              ),
              const DropdownMenuItem(value: 'vp9', child: Text('VP9 (WebM)')),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _generatePreview() async {
    if (_originalController == null) return;
    
    // Cancel previous task if running
    _currentPreviewTask?.cancel();
    
    setState(() {
      _isPreviewing = true;
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final originalClipPath = '${tempDir.path}/preview_original.mp4';
      // Always use .mp4 for playback compatibility on macOS
      final compressedClipPath = '${tempDir.path}/preview_compressed.mp4';
      final tempVp9Path = '${tempDir.path}/temp_vp9.webm';
      
      // Calculate start time
      final startTime = _videoDuration.inMilliseconds * _scrubPosition / 1000.0;
      final startTimeStr = startTime.toStringAsFixed(3);

      // 1. Extract original clip (2s)
      // Re-encode to ensure exact timing and sync with compressed clip
      // Use ultrafast preset for speed
      await _ffmpegService.execute(
        '-y -ss $startTimeStr -t 2 -i "${widget.file.path}" -c:v libx264 -preset ultrafast -an "$originalClipPath"'
      ).then((task) => task.done);

      // 2. Compress clip (2s)
      String codec;
      String speed = '';
      
      if (_outputFormat == 'av1') {
        if (_hasAv1Hardware) {
          codec = 'av1_videotoolbox';
          // VideoToolbox doesn't use -cpu-used
        } else {
          codec = 'libaom-av1';
          speed = '-cpu-used 8'; // Fastest for preview
        }
      } else {
        codec = 'libvpx-vp9';
        speed = '-speed 8'; // Fastest for preview
      }
      
      debugPrint('Generating preview with codec: $codec');
      
      if (_outputFormat == 'vp9') {
        // 1. Compress to VP9 (to generate artifacts)
        final vp9Task = await _ffmpegService.execute(
          '-y -ss $startTimeStr -t 2 -i "${widget.file.path}" -vf scale=-2:720 -c:v $codec -b:v ${_bitrate.round()}k $speed -an "$tempVp9Path"'
        );
        _currentPreviewTask = vp9Task;
        await vp9Task.done;

        // 2. Transcode to H.264 for playback
        final transcodeTask = await _ffmpegService.execute(
          '-y -i "$tempVp9Path" -c:v libx264 -preset ultrafast -an "$compressedClipPath"'
        );
        _currentPreviewTask = transcodeTask;
        await transcodeTask.done;
      } else {
        // AV1 (or others) - direct compression to MP4
        final task = await _ffmpegService.execute(
          '-y -ss $startTimeStr -t 2 -i "${widget.file.path}" -vf scale=-2:720 -c:v $codec -b:v ${_bitrate.round()}k $speed -an "$compressedClipPath"'
        );
        _currentPreviewTask = task;
        await task.done;
      }

      // 3. Update players
      final oldOriginal = _originalController;
      final oldCompressed = _compressedController;

      final newOriginal = VideoPlayerController.file(File(originalClipPath));
      final newCompressed = VideoPlayerController.file(File(compressedClipPath));

      await Future.wait([
        newOriginal.initialize(),
        newCompressed.initialize(),
      ]);

      await newOriginal.setLooping(true);
      await newCompressed.setLooping(true);
      
      // Sync play
      await newOriginal.play();
      await newCompressed.play();

      if (mounted) {
        setState(() {
          _originalController = newOriginal;
          _compressedController = newCompressed;
          _isPreviewing = false;
        });
      }

      // Dispose old controllers
      oldOriginal?.dispose();
      oldCompressed?.dispose();

    } catch (e) {
      if (e.toString().contains('cancelled')) {
        debugPrint('Preview generation cancelled');
      } else {
        debugPrint('Error generating preview: $e');
      }
      if (mounted) {
        setState(() {
          _isPreviewing = false;
        });
      }
    }
  }

  Future<void> _saveVideo() async {
    setState(() {
      _isCompressing = true;
      _progress = 0.0;
    });

    try {
      final FileSaveLocation? result = await getSaveLocation(
        suggestedName: 'compressed.${_outputFormat == 'vp9' ? 'webm' : 'mp4'}',
        acceptedTypeGroups: [
          XTypeGroup(
            label: 'Videos',
            extensions: [_outputFormat == 'vp9' ? 'webm' : 'mp4'],
          ),
        ],
      );

      if (result == null) {
        setState(() {
          _isCompressing = false;
        });
        return;
      }

      String codec;
      String speed = '';
      
      if (_outputFormat == 'av1') {
        if (_hasAv1Hardware) {
          codec = 'av1_videotoolbox';
        } else {
          codec = 'libaom-av1';
          speed = '-cpu-used 4'; // Better quality for final output
        }
      } else {
        codec = 'libvpx-vp9';
        speed = '-speed 4'; // Better quality for final output
      }

      debugPrint('Saving video with codec: $codec');

      final task = await _ffmpegService.execute(
        '-y -i "${widget.file.path}" -c:v $codec -b:v ${_bitrate.round()}k $speed "${result.path}"',
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _progress = progress;
            });
          }
        },
        totalDuration: _videoDuration,
      );
      await task.done;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video saved successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving video: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCompressing = false;
          _progress = 0.0;
        });
      }
    }
  }

  String _estimateSize() {
    // (Video Bitrate + Audio Bitrate) * Duration / 8
    // Assume 128kbps audio
    final totalBitrate = _bitrate + 128;
    final durationSeconds = _videoDuration.inSeconds;
    final sizeBytes = (totalBitrate * 1000 * durationSeconds) / 8;
    
    if (sizeBytes <= 0) return "~0 MB";
    
    final sizeMB = sizeBytes / (1024 * 1024);
    return '~${sizeMB.toStringAsFixed(1)} MB';
  }

  String _formatBytes(int bytes, [int decimals = 2]) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
    var i = (bytes.toString().length - 1) ~/ 3;
    i = 0;
    double v = bytes.toDouble();
    while (v >= 1024 && i < suffixes.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(decimals)} ${suffixes[i]}';
  }
}