import 'dart:io';

import '../model/run.dart';
import '../services/core/app_error.dart';
import '../services/core/app_logger.dart';
import 'atomic_file.dart';
import 'project_paths.dart';

class RunsStore {
  final ProjectPaths paths;
  final AppLogger logger;

  RunsStore({required this.paths, required this.logger});

  Future<Run?> getById(String runId) async {
    final raw = await AtomicFile.readJsonOrNull(paths.runFile(runId));
    if (raw is! Map) {
      return null;
    }
    return Run.fromJson(raw.cast<String, Object?>());
  }

  Future<List<Run>> listByBatch(String batchId) async {
    try {
      if (!await paths.runsDir.exists()) {
        return <Run>[];
      }
      final files = await paths.runsDir
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();
      final runs = <Run>[];
      for (final f in files) {
        final raw = await AtomicFile.readJsonOrNull(f);
        if (raw is Map) {
          final run = Run.fromJson(raw.cast<String, Object?>());
          if (run.batchId == batchId) {
            runs.add(run);
          }
        }
      }
      runs.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      return runs;
    } on Object catch (e) {
      logger.error('runs.list.failed', data: {'error': e.toString()});
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '读取 Run 失败',
        message: '无法读取 runs 目录。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }

  Future<void> write(Run run) async {
    try {
      await paths.ensureExists();
      await AtomicFile.writeJson(paths.runFile(run.id), run.toJson());
    } on Object catch (e) {
      logger.error(
        'runs.write.failed',
        data: {'error': e.toString(), 'id': run.id},
      );
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '保存 Run 失败',
        message: '无法写入 Run 文件。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }
}
