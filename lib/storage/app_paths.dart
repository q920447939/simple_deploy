import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppPaths {
  final Directory rootDir;

  const AppPaths({required this.rootDir});

  static Future<AppPaths> resolve({required String appName}) async {
    final supportDir = await getApplicationSupportDirectory();
    final rootPath = p.basename(supportDir.path) == appName
        ? supportDir.path
        : p.join(supportDir.path, appName);
    return AppPaths(rootDir: Directory(rootPath));
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
