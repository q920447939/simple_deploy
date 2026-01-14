import 'dart:convert';
import 'dart:io';

import '../services/core/app_error.dart';

class BatchLockInfo {
  final String runId;
  final int pid;
  final DateTime createdAt;

  const BatchLockInfo({
    required this.runId,
    required this.pid,
    required this.createdAt,
  });

  static BatchLockInfo fromJson(Map<String, Object?> json) {
    return BatchLockInfo(
      runId: json['run_id'] as String,
      pid: (json['pid'] as num?)?.toInt() ?? -1,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'run_id': runId,
      'pid': pid,
      'created_at': createdAt.toIso8601String(),
    };
  }
}

class BatchLock {
  static Future<BatchLockInfo?> readOrNull(File lockFile) async {
    if (!await lockFile.exists()) {
      return null;
    }
    try {
      final text = await lockFile.readAsString();
      if (text.trim().isEmpty) {
        return null;
      }
      final raw = jsonDecode(text);
      if (raw is! Map) {
        return null;
      }
      return BatchLockInfo.fromJson(raw.cast<String, Object?>());
    } on Object {
      return null;
    }
  }

  static Future<void> acquire(File lockFile, BatchLockInfo info) async {
    try {
      await lockFile.parent.create(recursive: true);
      await lockFile.create(exclusive: true);
      await lockFile.writeAsString(
        '${jsonEncode(info.toJson())}\n',
        flush: true,
      );
    } on FileSystemException {
      throw const AppException(
        code: AppErrorCode.batchLocked,
        title: '批次已在运行中',
        message: '该批次已存在锁文件（同批次互斥）。',
        suggestion: '等待当前 Run 结束，或使用“强制解锁/重置”为异常恢复入口。',
      );
    } on Object catch (e) {
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '创建锁失败',
        message: '无法创建批次锁文件。',
        suggestion: '检查本机磁盘权限与剩余空间。',
        cause: e,
      );
    }
  }

  static Future<void> release(File lockFile) async {
    if (await lockFile.exists()) {
      await lockFile.delete();
    }
  }
}
