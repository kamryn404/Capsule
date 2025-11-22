import 'dart:async';
import 'dart:io';

import 'package:camera_macos/camera_macos.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

enum CaptureMode { photo, video }

class CameraView extends StatefulWidget {
  final ValueChanged<XFile> onCapture;
  final VoidCallback onClose;

  const CameraView({
    super.key,
    required this.onCapture,
    required this.onClose,
  });

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  CaptureMode _mode = CaptureMode.photo;
  CameraMacOSController? _cameraController;
  
  bool _isRecording = false;
  final GlobalKey _cameraKey = GlobalKey();

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    CameraMacOS.instance.destroy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Preview Area
        Positioned.fill(
          child: Container(
            color: Colors.transparent,
            child: _buildPreview(),
          ),
        ),

        // Close Button
        Positioned(
          top: 10,
          right: 10,
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: widget.onClose,
            tooltip: 'Close Camera',
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
    return CameraMacOSView(
      key: _cameraKey,
      fit: BoxFit.contain,
      cameraMode: CameraMacOSMode.photo,
      onCameraInizialized: (CameraMacOSController controller) {
        setState(() {
          _cameraController = controller;
        });
      },
    );
  }

  Widget _buildModeButton(CaptureMode mode, String label) {
    final isSelected = _mode == mode;
    return GestureDetector(
      onTap: () {
        if (!_isRecording) {
          setState(() {
            _mode = mode;
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
    if (_cameraController == null) return;
    try {
      debugPrint('Taking photo...');
      final file = await _cameraController!.takePicture();
      if (file != null) {
        if (file.url != null) {
          debugPrint('Photo taken: ${file.url}');
          widget.onCapture(XFile(file.url!));
        } else if (file.bytes != null) {
          debugPrint('Photo taken (bytes): ${file.bytes!.length} bytes');
          final tempDir = await getTemporaryDirectory();
          final path = '${tempDir.path}/photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
          await File(path).writeAsBytes(file.bytes!);
          widget.onCapture(XFile(path));
        } else {
          debugPrint('Photo failed: url and bytes are null');
        }
      } else {
        debugPrint('Photo failed: file is null');
      }
    } catch (e) {
      debugPrint('Error taking photo: $e');
    }
  }

  Future<void> _startVideo() async {
    if (_cameraController == null) return;
    try {
      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/video_capture_${DateTime.now().millisecondsSinceEpoch}.mp4';
      
      debugPrint('Starting video recording to $path');
      await _cameraController!.recordVideo(
        url: path,
        onVideoRecordingFinished: (CameraMacOSFile? file, CameraMacOSException? error) {
           if (error != null) {
             debugPrint('Video recording error: $error');
           }
           if (file != null && file.url != null) {
             debugPrint('Video recording finished: ${file.url}');
             widget.onCapture(XFile(file.url!));
           }
        }
      );
      
      setState(() {
        _isRecording = true;
      });
    } catch (e) {
      debugPrint('Error starting video: $e');
    }
  }

  Future<void> _stopVideo() async {
    if (_cameraController == null) return;
    try {
      debugPrint('Stopping video recording...');
      final file = await _cameraController!.stopRecording();
      setState(() {
        _isRecording = false;
      });
      
      if (file != null && file.url != null) {
        debugPrint('Video stopped and file returned: ${file.url}');
        widget.onCapture(XFile(file.url!));
      }
    } catch (e) {
      debugPrint('Error stopping video: $e');
    }
  }
}