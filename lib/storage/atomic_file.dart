import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class AtomicFile {
  static Future<void> writeString(File file, String contents) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    final raf = await tmp.open(mode: FileMode.write);
    try {
      await raf.writeString(contents);
      await raf.flush();
    } finally {
      await raf.close();
    }

    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // Windows may not allow renaming over an existing file. Keep a backup to
      // avoid losing data if the process crashes mid-way.
      final backup = File('${file.path}.bak');
      if (await backup.exists()) {
        await backup.delete();
      }
      if (await file.exists()) {
        await file.rename(backup.path);
      }
      try {
        await tmp.rename(file.path);
        if (await backup.exists()) {
          await backup.delete();
        }
      } on Object {
        // Best-effort restore.
        if (!await file.exists() && await backup.exists()) {
          await backup.rename(file.path);
        }
        rethrow;
      }
    }
  }

  static Future<void> writeJson(File file, Object jsonObject) async {
    final contents = const JsonEncoder.withIndent('  ').convert(jsonObject);
    await writeString(file, '$contents\n');
  }

  static Future<Object?> readJsonOrNull(File file) async {
    if (!await file.exists()) {
      return null;
    }
    final text = await file.readAsString();
    if (text.trim().isEmpty) {
      return null;
    }
    return jsonDecode(text) as Object?;
  }

  static File childFile(Directory dir, String name) =>
      File(p.join(dir.path, name));
}
