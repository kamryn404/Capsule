import 'dart:ui';

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'views/audio_record_view.dart';
import 'views/camera_view.dart';
import 'views/compress_view.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(800, 600),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );
  
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Capsule Compressor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

enum AppMode { home, camera, audio, compress }

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  AppMode _appMode = AppMode.home;
  XFile? _capturedFile;
  bool _dragging = false;

  Future<void> _pickFile() async {
    const XTypeGroup typeGroup = XTypeGroup(
      label: 'media',
      extensions: <String>['jpg', 'jpeg', 'png', 'webp', 'mp4', 'mov', 'avi', 'mkv', 'mp3', 'wav', 'm4a', 'ogg'],
    );
    final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
    if (file != null) {
      setState(() {
        _capturedFile = file;
        _appMode = AppMode.compress;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      body: DropTarget(
        onDragDone: (detail) {
          setState(() {
            _dragging = false;
            if (detail.files.isNotEmpty) {
              final file = detail.files.first;
              final ext = p.extension(file.path).toLowerCase();
              if (['.jpg', '.jpeg', '.png', '.webp', '.avif', '.heic', '.mp4', '.webm', '.mkv', '.mov', '.avi', '.mp3', '.aac', '.ogg', '.wav', '.flac', '.m4a', '.opus', '.aiff'].contains(ext)) {
                _capturedFile = file;
                _appMode = AppMode.compress;
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Unsupported file format')),
                );
              }
            }
          });
        },
        onDragEntered: (detail) {
          setState(() {
            _dragging = true;
          });
        },
        onDragExited: (detail) {
          setState(() {
            _dragging = false;
          });
        },
        child: Stack(
          children: [
            // Main Content
            Positioned.fill(
              child: _buildContent(),
            ),

            // Drag Overlay
            if (_dragging)
              Positioned(
                top: 20,
                left: 20,
                right: 20,
                bottom: 20,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: CustomPaint(
                    painter: DashedBorderPainter(
                      color: Colors.blue,
                      strokeWidth: 4.0,
                      gap: 10.0,
                      radius: 12.0,
                    ),
                  ),
                ),
              ),

            // Draggable Titlebar Area
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 28,
              child: GestureDetector(
                onPanStart: (details) {
                  windowManager.startDragging();
                },
                child: Container(
                  color: Colors.transparent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (_appMode) {
      case AppMode.camera:
        return CameraView(
          onCapture: (file) {
            setState(() {
              _capturedFile = file;
              _appMode = AppMode.compress;
            });
          },
          onClose: () {
            setState(() {
              _appMode = AppMode.home;
            });
          },
        );
      case AppMode.audio:
        return AudioRecordView(
          onCapture: (file) {
            setState(() {
              _capturedFile = file;
              _appMode = AppMode.compress;
            });
          },
          onClose: () {
            setState(() {
              _appMode = AppMode.home;
            });
          },
        );
      case AppMode.compress:
        return CompressView(
          initialFile: _capturedFile,
          onClose: () {
            setState(() {
              _capturedFile = null;
              _appMode = AppMode.home;
            });
          },
        );
      case AppMode.home:
      default:
        return _buildHome();
    }
  }

  Widget _buildHome() {
    return Container(
      color: Colors.transparent,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.cloud_upload_outlined,
              size: 100,
              color: Colors.white54,
            ),
            const SizedBox(height: 20),
            const Text(
              'Drag and drop media here',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w300,
              ),
            ),
            const SizedBox(height: 40),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildActionButton(
                  icon: Icons.folder_open,
                  label: 'Select media...',
                  onTap: _pickFile,
                ),
                const SizedBox(height: 16),
                _buildActionButton(
                  icon: Icons.camera_alt,
                  label: 'Open Camera',
                  onTap: () {
                    setState(() {
                      _appMode = AppMode.camera;
                    });
                  },
                ),
                const SizedBox(height: 16),
                _buildActionButton(
                  icon: Icons.mic,
                  label: 'Record Audio',
                  onTap: () {
                    setState(() {
                      _appMode = AppMode.audio;
                    });
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: 200,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          backgroundColor: Colors.white10,
          foregroundColor: Colors.white,
          alignment: Alignment.center,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

class DashedBorderPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double gap;
  final double radius;

  DashedBorderPainter({
    this.color = Colors.white,
    this.strokeWidth = 2.0,
    this.gap = 5.0,
    this.radius = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final Path path = Path();
    path.addRRect(RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(radius),
    ));

    final Path dashPath = Path();
    final double dashWidth = 15.0;
    final double dashSpace = gap;
    double distance = 0.0;

    for (final PathMetric metric in path.computeMetrics()) {
      while (distance < metric.length) {
        dashPath.addPath(
          metric.extractPath(distance, distance + dashWidth),
          Offset.zero,
        );
        distance += dashWidth + dashSpace;
      }
    }
    canvas.drawPath(dashPath, paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
