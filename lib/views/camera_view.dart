import 'dart:async';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

// Platform-specific imports
import 'package:camera/camera.dart' as camera_pkg;
import 'package:camera_macos/camera_macos.dart' as camera_macos;

enum CaptureMode { photo, video }

class CameraView extends StatefulWidget {
  final ValueChanged<XFile> onCapture;

  const CameraView({
    super.key,
    required this.onCapture,
  });

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  CaptureMode _mode = CaptureMode.photo;
  
  // Standard camera controller (for non-macOS)
  camera_pkg.CameraController? _cameraController;
  List<camera_pkg.CameraDescription>? _cameras;
  
  // macOS-specific camera controller (received from CameraMacOSView callback)
  camera_macos.CameraMacOSController? _macOSController;
  
  bool _isRecording = false;
  bool _isInitializing = true;
  String? _errorMessage;

  bool get _isMacOS => Platform.isMacOS;
  
  // Key to force rebuild of CameraMacOSView when mode changes
  Key? _macOSViewKey;

  @override
  void initState() {
    super.initState();
    _macOSViewKey = UniqueKey();
    if (!_isMacOS) {
      _initializeStandardCamera();
    }
  }

  camera_macos.CameraMacOSMode get _macOSCameraMode {
    return _mode == CaptureMode.photo 
        ? camera_macos.CameraMacOSMode.photo 
        : camera_macos.CameraMacOSMode.video;
  }

  Future<void> _initializeStandardCamera() async {
    try {
      _cameras = await camera_pkg.availableCameras();
      if (_cameras != null && _cameras!.isNotEmpty) {
        final camera = _cameras!.first;
        _cameraController = camera_pkg.CameraController(
          camera,
          camera_pkg.ResolutionPreset.max,
          enableAudio: true,
        );

        await _cameraController!.initialize();
        if (mounted) {
          setState(() {
            _isInitializing = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isInitializing = false;
            _errorMessage = 'No cameras found';
          });
        }
      }
    } catch (e) {
      debugPrint('Error initializing camera: $e');
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _errorMessage = 'Error initializing camera: $e';
        });
      }
    }
  }

  void _onMacOSCameraInitialized(camera_macos.CameraMacOSController controller) {
    debugPrint('macOS camera initialized');
    _macOSController = controller;
    if (mounted) {
      setState(() {
        _isInitializing = false;
      });
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _macOSController?.destroy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Preview Area
        Positioned.fill(
          child: Container(
            color: Colors.grey[900],
            child: _buildPreview(),
          ),
        ),


        // Controls
        Positioned(
          bottom: 30,
          left: 0,
          right: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Mode Switcher
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildModeButton(CaptureMode.photo, 'Photo'),
                    const SizedBox(width: 16),
                    _buildModeButton(CaptureMode.video, 'Video'),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              
              // Capture Button
              GestureDetector(
                onTap: _onCaptureTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                    color: _isRecording ? Colors.red : Colors.white,
                  ),
                  child: _isRecording
                      ? Center(
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        )
                      : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    if (_isMacOS) {
      return _buildMacOSPreview();
    } else {
      return _buildStandardPreview();
    }
  }

  Widget _buildMacOSPreview() {
    if (_errorMessage != null) {
      return Center(child: Text(_errorMessage!, style: const TextStyle(color: Colors.white)));
    }
    
    return camera_macos.CameraMacOSView(
      key: _macOSViewKey,
      cameraMode: _macOSCameraMode,
      fit: BoxFit.contain,
      pictureFormat: camera_macos.PictureFormat.jpg,
      videoFormat: camera_macos.VideoFormat.mp4,
      enableAudio: true,
      onCameraInizialized: _onMacOSCameraInitialized,
      onCameraLoading: (error) {
        if (error != null) {
          return Center(child: Text('Camera error: $error', style: const TextStyle(color: Colors.white)));
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }

  Widget _buildStandardPreview() {
    if (_isInitializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(child: Text(_errorMessage!, style: const TextStyle(color: Colors.white)));
    }
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Center(child: Text('Camera not initialized', style: TextStyle(color: Colors.white)));
    }

    return Center(
      child: AspectRatio(
        aspectRatio: _cameraController!.value.aspectRatio,
        child: camera_pkg.CameraPreview(_cameraController!),
      ),
    );
  }

  Widget _buildModeButton(CaptureMode mode, String label) {
    final isSelected = _mode == mode;
    return GestureDetector(
      onTap: () {
        if (!_isRecording && _mode != mode) {
          setState(() {
            _mode = mode;
            // On macOS, we need to reinitialize the camera when switching modes
            if (_isMacOS) {
              _isInitializing = true;
              _macOSController = null;
              _macOSViewKey = UniqueKey();
            }
          });
        }
      },
      child: Text(
        label,
        style: TextStyle(
          color: isSelected ? Colors.yellow : Colors.white,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          fontSize: 16,
        ),
      ),
    );
  }

  Future<void> _onCaptureTap() async {
    if (_isMacOS) {
      if (_macOSController == null) {
        debugPrint('macOS camera controller not ready');
        return;
      }
    } else {
      if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    }

    debugPrint('Capture tapped. Mode: $_mode, Recording: $_isRecording');
    if (_mode == CaptureMode.photo) {
      await _takePhoto();
    } else if (_mode == CaptureMode.video) {
      if (_isRecording) {
        await _stopVideo();
      } else {
        await _startVideo();
      }
    }
  }

  Future<void> _takePhoto() async {
    try {
      debugPrint('Taking photo...');
      if (_isMacOS) {
        debugPrint('macOS controller state: ${_macOSController != null}');
        final result = await _macOSController!.takePicture();
        debugPrint('takePicture result: $result');
        if (result != null) {
          debugPrint('Result url: ${result.url}, bytes: ${result.bytes?.length}');
          if (result.url != null && result.url!.isNotEmpty) {
            debugPrint('Photo taken on macOS: ${result.url}');
            widget.onCapture(XFile(result.url!));
          } else if (result.bytes != null && result.bytes!.isNotEmpty) {
            // If no URL but has bytes, save to temp file
            debugPrint('Photo has bytes, saving to temp file');
            final tempDir = await getTemporaryDirectory();
            final photoPath = '${tempDir.path}/camera_photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
            final file = File(photoPath);
            await file.writeAsBytes(result.bytes!);
            debugPrint('Photo saved to: $photoPath');
            widget.onCapture(XFile(photoPath));
          } else {
            debugPrint('Photo capture returned result but no URL or bytes');
          }
        } else {
          debugPrint('Photo capture returned null');
        }
      } else {
        final file = await _cameraController!.takePicture();
        debugPrint('Photo taken: ${file.path}');
        widget.onCapture(file);
      }
    } catch (e, stackTrace) {
      debugPrint('Error taking photo: $e');
      debugPrint('Stack trace: $stackTrace');
    }
  }

  Future<void> _startVideo() async {
    try {
      debugPrint('Starting video recording...');
      if (_isMacOS) {
        // Get temp directory for video recording
        final tempDir = await getTemporaryDirectory();
        final videoPath = '${tempDir.path}/camera_video_${DateTime.now().millisecondsSinceEpoch}.mp4';
        await _macOSController!.recordVideo(
          url: videoPath,
          enableAudio: true,
        );
      } else {
        await _cameraController!.startVideoRecording();
      }
      
      setState(() {
        _isRecording = true;
      });
    } catch (e) {
      debugPrint('Error starting video: $e');
    }
  }

  Future<void> _stopVideo() async {
    try {
      debugPrint('Stopping video recording...');
      if (_isMacOS) {
        final result = await _macOSController!.stopRecording();
        setState(() {
          _isRecording = false;
        });
        if (result != null && result.url != null) {
          debugPrint('Video stopped on macOS: ${result.url}');
          widget.onCapture(XFile(result.url!));
        } else {
          debugPrint('Video stop returned null or no URL');
        }
      } else {
        final file = await _cameraController!.stopVideoRecording();
        setState(() {
          _isRecording = false;
        });
        debugPrint('Video stopped and file returned: ${file.path}');
        widget.onCapture(file);
      }
    } catch (e) {
      debugPrint('Error stopping video: $e');
    }
  }
}