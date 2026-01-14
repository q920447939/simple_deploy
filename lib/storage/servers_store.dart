import '../model/server.dart';
import '../services/core/app_error.dart';
import '../services/core/app_logger.dart';
import 'atomic_file.dart';
import 'project_paths.dart';

class ServersStore {
  final ProjectPaths paths;
  final AppLogger logger;

  ServersStore({required this.paths, required this.logger});

  Future<List<Server>> list() async {
    try {
      final raw = await AtomicFile.readJsonOrNull(paths.serversFile);
      if (raw == null) {
        return <Server>[];
      }
      if (raw is! List) {
        throw const AppException(
          code: AppErrorCode.storageCorruptJson,
          title: '服务器文件损坏',
          message: 'servers.json 不是数组结构。',
          suggestion: '手动修复 JSON 或删除项目目录后重建。',
        );
      }
      return raw
          .whereType<Map>()
          .map((m) => Server.fromJson(m.cast<String, Object?>()))
          .toList();
    } on AppException {
      rethrow;
    } on Object catch (e) {
      logger.error('servers.list.failed', data: {'error': e.toString()});
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '读取服务器失败',
        message: '无法读取 servers.json。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }

  Future<void> upsert(Server server) async {
    final items = await list();
    final idx = items.indexWhere((s) => s.id == server.id);
    if (idx >= 0) {
      items[idx] = server;
    } else {
      items.add(server);
    }

    try {
      await paths.ensureExists();
      await AtomicFile.writeJson(
        paths.serversFile,
        items.map((s) => s.toJson()).toList(),
      );
    } on Object catch (e) {
      logger.error(
        'servers.upsert.failed',
        data: {'error': e.toString(), 'id': server.id},
      );
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '保存服务器失败',
        message: '无法写入 servers.json。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }

  Future<void> delete(String id) async {
    final items = await list();
    items.removeWhere((s) => s.id == id);
    try {
      await AtomicFile.writeJson(
        paths.serversFile,
        items.map((s) => s.toJson()).toList(),
      );
    } on Object catch (e) {
      logger.error(
        'servers.delete.failed',
        data: {'error': e.toString(), 'id': id},
      );
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '删除服务器失败',
        message: '无法更新 servers.json。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }
}
