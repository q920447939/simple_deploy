import 'dart:io';

import '../model/project.dart';
import '../services/core/app_error.dart';
import '../services/core/app_logger.dart';
import 'atomic_file.dart';
import 'project_paths.dart';

class ProjectsStore {
  final File file;
  final Directory projectsDir;
  final AppLogger logger;

  ProjectsStore({
    required this.file,
    required this.projectsDir,
    required this.logger,
  });

  Future<List<Project>> list() async {
    try {
      final raw = await AtomicFile.readJsonOrNull(file);
      if (raw == null) {
        return <Project>[];
      }
      if (raw is! List) {
        throw const AppException(
          code: AppErrorCode.storageCorruptJson,
          title: '项目索引文件损坏',
          message: 'projects.json 不是数组结构。',
          suggestion: '删除本地数据目录后重新创建，或手动修复 JSON。',
        );
      }
      return raw
          .whereType<Map>()
          .map((m) => Project.fromJson(m.cast<String, Object?>()))
          .toList();
    } on AppException {
      rethrow;
    } on Object catch (e) {
      logger.error('projects.list.failed', data: {'error': e.toString()});
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '读取项目失败',
        message: '无法读取本地项目列表。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }

  Future<void> upsert(Project project) async {
    final projects = await list();
    final idx = projects.indexWhere((p) => p.id == project.id);
    if (idx >= 0) {
      projects[idx] = project;
    } else {
      projects.add(project);
    }

    try {
      await projectsDir.create(recursive: true);
      final pp = ProjectPaths(projectsRoot: projectsDir, projectId: project.id);
      await pp.ensureExists();
      await AtomicFile.writeJson(pp.projectFile, project.toJson());
      await AtomicFile.writeJson(
        file,
        projects.map((p) => p.toJson()).toList(),
      );
    } on Object catch (e) {
      logger.error(
        'projects.upsert.failed',
        data: {'error': e.toString(), 'id': project.id},
      );
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '保存项目失败',
        message: '无法写入本地项目列表。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }

  Future<void> delete(String projectId) async {
    final projects = await list();
    projects.removeWhere((p) => p.id == projectId);
    try {
      await AtomicFile.writeJson(
        file,
        projects.map((p) => p.toJson()).toList(),
      );
      final dir = ProjectPaths(
        projectsRoot: projectsDir,
        projectId: projectId,
      ).projectDir;
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } on Object catch (e) {
      logger.error(
        'projects.delete.failed',
        data: {'error': e.toString(), 'id': projectId},
      );
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '删除项目失败',
        message: '无法更新本地项目列表。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }
}
