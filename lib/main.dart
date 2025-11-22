import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:cross_file/cross_file.dart';
import 'package:window_manager/window_manager.dart';

import 'audio_editor.dart';
import 'image_editor.dart';
import 'video_editor.dart';

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
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  XFile? _droppedFile;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Main Content
          Positioned.fill(
            child: DropTarget(
              onDragDone: (detail) {
                setState(() {
                  if (detail.files.isNotEmpty) {
                    final file = detail.files.first;
                    final ext = p.extension(file.path).toLowerCase();
                    if (['.jpg', '.jpeg', '.png', '.webp', '.avif', '.mp4', '.webm', '.mkv', '.mov', '.avi', '.mp3', '.aac', '.ogg', '.wav', '.flac', '.m4a', '.opus'].contains(ext)) {
                      _droppedFile = file;
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Unsupported file format')),
                      );
                    }
                  }
                  _dragging = false;
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
              child: Container(
                color: _dragging ? Colors.blue.withValues(alpha: 0.2) : Colors.black12,
                child: _buildContent(),
              ),
            ),
          ),

          // Draggable Titlebar Area
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 28, // Standard macOS titlebar height
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
    );
  }

  Widget _buildContent() {
    if (_droppedFile == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.upload_file, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'Drag and drop an image or video here',
              style: TextStyle(fontSize: 20, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    final ext = p.extension(_droppedFile!.path).toLowerCase();
    if (['.mp4', '.webm', '.mkv', '.mov', '.avi'].contains(ext)) {
      return VideoEditor(
        file: _droppedFile!,
        onClear: () {
          setState(() {
            _droppedFile = null;
          });
        },
      );
    } else if (['.mp3', '.aac', '.ogg', '.wav', '.flac', '.m4a', '.opus'].contains(ext)) {
      return AudioEditor(
        file: _droppedFile!,
        onClear: () {
          setState(() {
            _droppedFile = null;
          });
        },
      );
    } else {
      return ImageEditor(
        file: _droppedFile!,
        onClear: () {
          setState(() {
            _droppedFile = null;
          });
        },
      );
    }
  }
}
