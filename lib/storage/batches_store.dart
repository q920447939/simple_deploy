import 'dart:io';

import '../model/batch.dart';
import '../services/core/app_error.dart';
import '../services/core/app_logger.dart';
import 'atomic_file.dart';
import 'project_paths.dart';

class BatchesStore {
  final ProjectPaths paths;
  final AppLogger logger;

  BatchesStore({required this.paths, required this.logger});

  Future<List<Batch>> list() async {
    try {
      if (!await paths.batchesDir.exists()) {
        return <Batch>[];
      }
      final files = await paths.batchesDir
          .list()
          .where((e) {
            if (e is! File) return false;
            final p = e.path;
            if (!p.endsWith('.json')) return false;
            // Ignore auxiliary files stored under batches/ (not batch configs).
            return true;
          })
          .cast<File>()
          .toList();
      final batches = <Batch>[];
      for (final f in files) {
        final raw = await AtomicFile.readJsonOrNull(f);
        if (raw is Map) {
          batches.add(Batch.fromJson(raw.cast<String, Object?>()));
        }
      }
      batches.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return batches;
    } on Object catch (e) {
      logger.error('batches.list.failed', data: {'error': e.toString()});
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '读取批次失败',
        message: '无法读取批次文件。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }

  Future<Batch?> getById(String batchId) async {
    final raw = await AtomicFile.readJsonOrNull(paths.batchFile(batchId));
    if (raw is! Map) {
      return null;
    }
    return Batch.fromJson(raw.cast<String, Object?>());
  }

  Future<void> upsert(Batch batch) async {
    try {
      await paths.ensureExists();
      await AtomicFile.writeJson(paths.batchFile(batch.id), batch.toJson());
    } on Object catch (e) {
      logger.error(
        'batches.upsert.failed',
        data: {'error': e.toString(), 'id': batch.id},
      );
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '保存批次失败',
        message: '无法写入批次文件。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }

  Future<void> delete(String batchId) async {
    final file = paths.batchFile(batchId);
    try {
      if (await file.exists()) {
        await file.delete();
      }
      final lock = paths.batchLockFile(batchId);
      if (await lock.exists()) {
        await lock.delete();
      }
    } on Object catch (e) {
      logger.error(
        'batches.delete.failed',
        data: {'error': e.toString(), 'id': batchId},
      );
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '删除批次失败',
        message: '无法删除批次文件/锁文件。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }
}
