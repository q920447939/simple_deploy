import 'dart:convert';

import '../../model/task_template.dart';
import '../core/app_error.dart';
import '../offline_assets/offline_assets.dart';

class TaskTemplateStore {
  final OfflineAssets assets;

  TaskTemplateStore({OfflineAssets? assets})
    : assets = assets ?? OfflineAssets.locate();

  Future<List<TaskTemplate>> list() async {
    final file = assets.file('assets/templates/templates.json');
    if (!await file.exists()) {
      return <TaskTemplate>[];
    }
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: '模板索引损坏',
          message: 'templates.json 不是数组结构。',
          suggestion: '请检查 assets/templates/templates.json。',
        );
      }
      return raw
          .whereType<Map>()
          .map((m) => TaskTemplate.fromJson(m.cast<String, Object?>()))
          .toList();
    } on AppException {
      rethrow;
    } on Object catch (e) {
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '读取模板失败',
        message: '无法读取 templates.json。',
        suggestion: '检查安装包 assets 或磁盘权限。',
        cause: e,
      );
    }
  }

  Future<String> readPlaybookText(TaskTemplate template) async {
    final path = template.playbookPath;
    if (path == null || path.trim().isEmpty) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '模板不完整',
        message: '模板缺少 playbook_path。',
        suggestion: '请更新模板索引或联系管理员。',
      );
    }
    final file = assets.file(path);
    if (!await file.exists()) {
      throw AppException(
        code: AppErrorCode.validation,
        title: '模板 Playbook 不存在',
        message: '未找到模板 Playbook：$path',
        suggestion: '请检查安装包 assets 是否完整。',
      );
    }
    return file.readAsString();
  }
}
