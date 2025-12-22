import 'dart:io';

import 'package:flutter_app_packager/src/makers/exe/inno_setup/inno_setup_script.dart';
import 'package:path/path.dart' as p;
import 'package:shell_executor/shell_executor.dart';

class InnoSetupCompiler {
  Future<String?> _findISCC() async {
    print('LOCAL_FIX_DEBUG: Searching for ISCC...');
    List<String> paths = [
      'C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe',
      'C:\\Program Files\\Inno Setup 6\\ISCC.exe',
    ];
    for (var path in paths) {
      print('LOCAL_FIX_DEBUG: Checking path: $path');
      if (File(path).existsSync()) {
        print('LOCAL_FIX_DEBUG: Found ISCC at: $path');
        return path;
      }
    }
    print('LOCAL_FIX_DEBUG: Falling back to `cmd /c where iscc`');
    try {
      ProcessResult result = await Process.run('cmd', ['/c', 'where iscc']);
      print('LOCAL_FIX_DEBUG: `where iscc` exit code: ${result.exitCode}');
      print('LOCAL_FIX_DEBUG: `where iscc` stdout: ${result.stdout}');
      if (result.exitCode == 0) {
        String path = (result.stdout as String).split('\r\n').first.trim();
        if (path.isEmpty) {
          path = (result.stdout as String).split('\n').first.trim();
        }
        print('LOCAL_FIX_DEBUG: Found ISCC via path: $path');
        return path;
      }
    } catch (e) {
      print('LOCAL_FIX_DEBUG: Error running `where iscc`: $e');
    }
    print('LOCAL_FIX_DEBUG: ISCC NOT FOUND');
    return null;
  }

  Future<bool> compile(InnoSetupScript script) async {
    String? isccPath = await _findISCC();

    if (isccPath == null) {
      throw Exception('`Inno Setup 6` was not installed.');
    }

    File file = await script.createFile();

    ProcessResult processResult = await $(
      isccPath,
      [file.path],
    );

    if (processResult.exitCode != 0) {
      return false;
    }

    file.deleteSync(recursive: true);
    return true;
  }
}
