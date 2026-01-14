import '../model/task.dart';
import '../services/core/app_error.dart';
import '../services/core/app_logger.dart';
import 'atomic_file.dart';
import 'project_paths.dart';

class TasksStore {
  final ProjectPaths paths;
  final AppLogger logger;

  TasksStore({required this.paths, required this.logger});

  Future<List<Task>> list() async {
    try {
      final raw = await AtomicFile.readJsonOrNull(paths.tasksFile);
      if (raw == null) {
        return <Task>[];
      }
      if (raw is! List) {
        throw const AppException(
          code: AppErrorCode.storageCorruptJson,
          title: '任务文件损坏',
          message: 'tasks.json 不是数组结构。',
          suggestion: '手动修复 JSON 或删除项目目录后重建。',
        );
      }
      return raw
          .whereType<Map>()
          .map((m) => Task.fromJson(m.cast<String, Object?>()))
          .toList();
    } on AppException {
      rethrow;
    } on Object catch (e) {
      logger.error('tasks.list.failed', data: {'error': e.toString()});
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '读取任务失败',
        message: '无法读取 tasks.json。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }

  Future<void> upsert(Task task) async {
    final items = await list();
    final idx = items.indexWhere((t) => t.id == task.id);
    if (idx >= 0) {
      items[idx] = task;
    } else {
      items.add(task);
    }

    try {
      await paths.ensureExists();
      await AtomicFile.writeJson(
        paths.tasksFile,
        items.map((t) => t.toJson()).toList(),
      );
    } on Object catch (e) {
      logger.error(
        'tasks.upsert.failed',
        data: {'error': e.toString(), 'id': task.id},
      );
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '保存任务失败',
        message: '无法写入 tasks.json。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }

  Future<void> delete(String id) async {
    final items = await list();
    items.removeWhere((t) => t.id == id);
    try {
      await AtomicFile.writeJson(
        paths.tasksFile,
        items.map((t) => t.toJson()).toList(),
      );
    } on Object catch (e) {
      logger.error(
        'tasks.delete.failed',
        data: {'error': e.toString(), 'id': id},
      );
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '删除任务失败',
        message: '无法更新 tasks.json。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }
}
