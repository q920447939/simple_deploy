import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/playbook_meta.dart';
import '../services/core/app_error.dart';
import '../services/core/app_logger.dart';
import 'atomic_file.dart';
import 'project_paths.dart';

class PlaybooksStore {
  final ProjectPaths paths;
  final AppLogger logger;

  PlaybooksStore({required this.paths, required this.logger});

  File playbookFile(String relativePath) {
    return File(p.join(paths.projectDir.path, relativePath));
  }

  Future<List<PlaybookMeta>> listMeta() async {
    try {
      final raw = await AtomicFile.readJsonOrNull(paths.playbooksIndexFile);
      if (raw == null) {
        return <PlaybookMeta>[];
      }
      if (raw is! List) {
        throw const AppException(
          code: AppErrorCode.storageCorruptJson,
          title: 'Playbooks 索引损坏',
          message: 'playbooks.json 不是数组结构。',
          suggestion: '手动修复 JSON 或删除项目目录后重建。',
        );
      }
      return raw
          .whereType<Map>()
          .map((m) => PlaybookMeta.fromJson(m.cast<String, Object?>()))
          .toList();
    } on AppException {
      rethrow;
    } on Object catch (e) {
      logger.error('playbooks.list.failed', data: {'error': e.toString()});
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '读取 Playbook 失败',
        message: '无法读取 playbooks.json。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }

  Future<void> upsertMeta(PlaybookMeta meta) async {
    final list = await listMeta();
    final idx = list.indexWhere((p) => p.id == meta.id);
    if (idx >= 0) {
      list[idx] = meta;
    } else {
      list.add(meta);
    }

    try {
      await paths.ensureExists();
      await AtomicFile.writeJson(
        paths.playbooksIndexFile,
        list.map((m) => m.toJson()).toList(),
      );
    } on Object catch (e) {
      logger.error(
        'playbooks.upsert_meta.failed',
        data: {'error': e.toString(), 'id': meta.id},
      );
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '保存 Playbook 失败',
        message: '无法写入 playbooks.json。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }

  Future<void> deletePlaybook(String playbookId) async {
    final list = await listMeta();
    final idx = list.indexWhere((m) => m.id == playbookId);
    if (idx < 0) {
      return;
    }

    final meta = list.removeAt(idx);
    try {
      await AtomicFile.writeJson(
        paths.playbooksIndexFile,
        list.map((m) => m.toJson()).toList(),
      );
      final file = playbookFile(meta.relativePath);
      if (await file.exists()) {
        await file.delete();
      }
    } on Object catch (e) {
      logger.error(
        'playbooks.delete.failed',
        data: {'error': e.toString(), 'id': playbookId},
      );
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '删除 Playbook 失败',
        message: '无法更新 playbooks.json 或删除 YAML 文件。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }

  Future<String> readPlaybookText(PlaybookMeta meta) async {
    final file = playbookFile(meta.relativePath);
    if (!await file.exists()) {
      return '';
    }
    return file.readAsString();
  }

  Future<void> writePlaybookText(PlaybookMeta meta, String contents) async {
    final file = playbookFile(meta.relativePath);
    try {
      await paths.ensureExists();
      await file.parent.create(recursive: true);
      await AtomicFile.writeString(
        file,
        contents.endsWith('\n') ? contents : '$contents\n',
      );
    } on Object catch (e) {
      logger.error(
        'playbooks.write_text.failed',
        data: {'error': e.toString(), 'id': meta.id},
      );
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '保存 Playbook 文件失败',
        message: '无法写入 YAML 文件。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }
}
