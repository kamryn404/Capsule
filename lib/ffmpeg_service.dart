import 'dart:convert';
import 'dart:io';
// import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
// import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class MediaInfo {
  final Duration duration;
  final int bitrate; // kbps

  MediaInfo({required this.duration, required this.bitrate});
}

class FfmpegTask {
  final Future<void> done;
  final VoidCallback cancel;

  FfmpegTask(this.done, this.cancel);
}

abstract class FfmpegService {
  Future<FfmpegTask> execute(String command, {void Function(double progress)? onProgress, Duration? totalDuration});
  Future<MediaInfo> getMediaInfo(String path);
  Future<bool> hasEncoder(String encoderName);
  Future<void> init();
}

class FfmpegServiceFactory {
  static FfmpegService create() {
    if (Platform.isAndroid || Platform.isIOS) {
      return MobileFfmpegService();
    } else {
      return DesktopFfmpegService();
    }
  }
}

class MobileFfmpegService implements FfmpegService {
  @override
  Future<void> init() async {
    // No initialization needed for mobile
  }

  @override
  Future<FfmpegTask> execute(String command, {void Function(double progress)? onProgress, Duration? totalDuration}) async {
    // Stub for now
    throw UnimplementedError('Mobile FFmpeg not implemented yet');
  }

  @override
  Future<MediaInfo> getMediaInfo(String path) async {
    throw UnimplementedError('Mobile FFmpeg not implemented yet');
  }

  @override
  Future<bool> hasEncoder(String encoderName) async {
    return false;
  }
}

class DesktopFfmpegService implements FfmpegService {
  String? _binaryPath;

  @override
  Future<void> init() async {
    if (_binaryPath != null) return;

    // Check for system ffmpeg first
    final systemPaths = [
      '/opt/homebrew/bin/ffmpeg', // Apple Silicon Homebrew
      '/usr/local/bin/ffmpeg',    // Intel Homebrew
      '/usr/bin/ffmpeg',          // System (rarely has codecs)
    ];

    for (final path in systemPaths) {
      if (await File(path).exists()) {
        _binaryPath = path;
        debugPrint('Using system FFmpeg at $_binaryPath');
        return;
      }
    }

    // Fallback to bundled ffmpeg
    final appDir = await getApplicationSupportDirectory();
    final binDir = Directory(p.join(appDir.path, 'bin'));
    if (!await binDir.exists()) {
      await binDir.create(recursive: true);
    }

    String binaryName = 'ffmpeg';
    if (Platform.isWindows) {
      binaryName = 'ffmpeg.exe';
    }

    final binaryFile = File(p.join(binDir.path, binaryName));

    // Always copy for now to ensure we have the latest asset
    // In production, might want to check version or existence
    final byteData = await rootBundle.load('assets/bin/$binaryName');
    final buffer = byteData.buffer;
    await binaryFile.writeAsBytes(
      buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
    );

    if (Platform.isMacOS || Platform.isLinux) {
      await Process.run('chmod', ['+x', binaryFile.path]);
    }

    _binaryPath = binaryFile.path;
    debugPrint('Using bundled FFmpeg at $_binaryPath');
  }

  @override
  Future<FfmpegTask> execute(String command, {void Function(double progress)? onProgress, Duration? totalDuration}) async {
    if (_binaryPath == null) {
      await init();
    }

    final args = _parseArgs(command);
    
    debugPrint('Executing: $_binaryPath ${args.join(' ')}');

    final process = await Process.start(_binaryPath!, args);
    bool isCancelled = false;

    // Listen to stderr for progress (FFmpeg writes stats to stderr)
    process.stderr.transform(utf8.decoder).listen((data) {
      // debugPrint('FFmpeg stderr: $data'); // Too verbose for rapid updates
      if (onProgress != null && totalDuration != null) {
        _parseProgress(data, totalDuration, onProgress);
      }
    });

    // Also listen to stdout just in case
    process.stdout.transform(utf8.decoder).listen((data) {
      debugPrint('FFmpeg stdout: $data');
    });

    final doneFuture = process.exitCode.then((exitCode) {
      if (isCancelled) {
        throw Exception('FFmpeg cancelled');
      }
      if (exitCode != 0) {
        throw Exception('FFmpeg failed with exit code $exitCode');
      }
    });

    return FfmpegTask(
      doneFuture,
      () {
        isCancelled = true;
        process.kill();
      },
    );
  }

  @override
  Future<MediaInfo> getMediaInfo(String path) async {
    if (_binaryPath == null) {
      await init();
    }

    // Run ffmpeg -i input
    final result = await Process.run(_binaryPath!, ['-i', path]);
    
    // Parse stderr (ffmpeg outputs info to stderr)
    final output = result.stderr.toString();
    
    // Parse Duration
    // Duration: 00:00:05.00
    final durationRegex = RegExp(r'Duration: (\d+):(\d+):(\d+\.\d+)');
    final durationMatch = durationRegex.firstMatch(output);
    Duration duration = Duration.zero;
    if (durationMatch != null) {
      final hours = int.parse(durationMatch.group(1)!);
      final minutes = int.parse(durationMatch.group(2)!);
      final seconds = double.parse(durationMatch.group(3)!);
      duration = Duration(
        hours: hours,
        minutes: minutes,
        milliseconds: (seconds * 1000).round(),
      );
    }

    // Parse Bitrate
    // bitrate: 21640 kb/s
    final bitrateRegex = RegExp(r'bitrate: (\d+) kb/s');
    final bitrateMatch = bitrateRegex.firstMatch(output);
    int bitrate = 0;
    if (bitrateMatch != null) {
      bitrate = int.parse(bitrateMatch.group(1)!);
    }

    return MediaInfo(duration: duration, bitrate: bitrate);
  }

  @override
  Future<bool> hasEncoder(String encoderName) async {
    if (_binaryPath == null) {
      await init();
    }

    // Run ffmpeg -encoders
    final result = await Process.run(_binaryPath!, ['-encoders']);
    final output = result.stdout.toString();
    
    debugPrint('Available encoders check for $encoderName');
    
    return output.contains(encoderName);
  }

  void _parseProgress(String data, Duration totalDuration, void Function(double) onProgress) {
    // Look for time=HH:MM:SS.mm
    final regex = RegExp(r'time=(\d+):(\d+):(\d+\.\d+)');
    final match = regex.firstMatch(data);
    if (match != null) {
      try {
        final hours = int.parse(match.group(1)!);
        final minutes = int.parse(match.group(2)!);
        final seconds = double.parse(match.group(3)!);
        
        final currentDuration = Duration(
          hours: hours,
          minutes: minutes,
          milliseconds: (seconds * 1000).round(),
        );

        final progress = currentDuration.inMilliseconds / totalDuration.inMilliseconds;
        onProgress(progress.clamp(0.0, 1.0));
      } catch (e) {
        // Ignore parsing errors
      }
    }
  }

  List<String> _parseArgs(String command) {
    // Simple regex to split by space but respect quotes
    final RegExp regex = RegExp(r'[^\s"]+|"([^"]*)"');
    return regex.allMatches(command).map((m) {
      if (m.group(1) != null) {
        return m.group(1)!;
      }
      return m.group(0)!;
    }).toList();
  }
}