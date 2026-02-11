import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

class LogService {
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();

  final List<String> _logs = [];
  File? _logFile;
  final DateFormat _dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');

  Future<void> init() async {
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      _logFile = File('${appDocDir.path}/app_logs.txt');

      // Clear old logs if they get too big (e.g., > 1MB)
      if (await _logFile!.exists()) {
        final size = await _logFile!.length();
        if (size > 1024 * 1024) {
          await _logFile!.writeAsString('');
        }
      } else {
        await _logFile!.create(recursive: true);
      }

      log('LogService initialized. Log file: ${_logFile!.path}');
    } catch (e) {
      debugPrint('Failed to initialize LogService: $e');
    }
  }

  void log(String message) {
    final timestamp = _dateFormat.format(DateTime.now());
    final logEntry = '[$timestamp] $message';

    _logs.add(logEntry);
    if (_logs.length > 1000) {
      _logs.removeAt(0);
    }

    debugPrint(logEntry);

    _writeToLogFile(logEntry);
  }

  void error(String message, [dynamic error, StackTrace? stackTrace]) {
    final timestamp = _dateFormat.format(DateTime.now());
    var logEntry = '[$timestamp] ERROR: $message';
    if (error != null) {
      logEntry += '\nError: $error';
    }
    if (stackTrace != null) {
      logEntry += '\nStackTrace: $stackTrace';
    }

    _logs.add(logEntry);
    if (_logs.length > 1000) {
      _logs.removeAt(0);
    }

    debugPrint(logEntry);
    if (stackTrace != null) {
      debugPrint(stackTrace.toString());
    }

    _writeToLogFile(logEntry);
  }

  Future<void> _writeToLogFile(String entry) async {
    try {
      if (_logFile != null) {
        await _logFile!.writeAsString(
          '$entry\n',
          mode: FileMode.append,
          flush: true,
        );
      }
    } catch (e) {
      // Ignore errors writing to log file
    }
  }

  String getLogs() {
    return _logs.join('\n');
  }

  Future<String> getLogFilePath() async {
    if (_logFile == null) {
      final appDocDir = await getApplicationDocumentsDirectory();
      return '${appDocDir.path}/app_logs.txt';
    }
    return _logFile!.path;
  }

  Future<void> clearLogs() async {
    _logs.clear();
    try {
      if (_logFile != null && await _logFile!.exists()) {
        await _logFile!.writeAsString('');
      }
    } catch (e) {
      // Ignore
    }
  }
}

final logger = LogService();
