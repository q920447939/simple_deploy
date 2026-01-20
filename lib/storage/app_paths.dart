import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppPaths {
  final Directory rootDir;

  const AppPaths({required this.rootDir});

  static Future<AppPaths> resolve({required String appName}) async {
    final envDir = Platform.environment['SIMPLE_DEPLOY_DATA_DIR']?.trim();
    final rootPath = envDir != null && envDir.isNotEmpty
        ? envDir
        : p.join(Directory.current.path, 'data');
    final rootDir = Directory(rootPath);

    final legacyRoot = await _resolveLegacyRoot(appName);
    if (p.normalize(legacyRoot.path) != p.normalize(rootDir.path)) {
      await _migrateLegacyData(legacyRoot, rootDir);
    }
    return AppPaths(rootDir: rootDir);
  }

  static Future<Directory> _resolveLegacyRoot(String appName) async {
    final supportDir = await getApplicationSupportDirectory();
    final rootPath = p.basename(supportDir.path) == appName
        ? supportDir.path
        : p.join(supportDir.path, appName);
    return Directory(rootPath);
  }

  static Future<void> _migrateLegacyData(
    Directory legacy,
    Directory target,
  ) async {
    if (!await legacy.exists()) return;
    if (await _dirHasEntries(target)) return;
    await target.create(recursive: true);
    await _copyDirectory(legacy, target);
  }

  static Future<bool> _dirHasEntries(Directory dir) async {
    if (!await dir.exists()) return false;
    await for (final _ in dir.list(followLinks: false)) {
      return true;
    }
    return false;
  }

  static Future<void> _copyDirectory(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final entity in src.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final next = p.join(dst.path, name);
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(next));
      } else if (entity is File) {
        await entity.copy(next);
      }
    }
  }

  Directory get projectsDir => Directory(p.join(rootDir.path, 'projects'));
  Directory get appLogsDir => Directory(p.join(rootDir.path, 'app_logs'));

  File get projectsIndexFile => File(p.join(projectsDir.path, 'projects.json'));
  File get appStateFile => File(p.join(rootDir.path, 'app_state.json'));

  Future<void> ensureExists() async {
    await rootDir.create(recursive: true);
    await projectsDir.create(recursive: true);
    await appLogsDir.create(recursive: true);
  }
}
