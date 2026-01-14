import 'package:get/get.dart';

import '../../model/file_slot.dart';
import '../../model/task.dart';
import '../../services/app_services.dart';
import '../../services/core/app_error.dart';
import '../../services/core/app_logger.dart';
import 'projects_controller.dart';

class TasksController extends GetxController {
  final ProjectsController projects = Get.find<ProjectsController>();

  final RxList<Task> tasks = <Task>[].obs;
  final RxnString selectedId = RxnString();

  AppLogger get _logger => AppServices.I.logger;

  String? get projectId => projects.selectedId.value;

  static final RegExp _slotNameRe = RegExp(r'^[A-Za-z0-9_]+$');

  @override
  void onInit() {
    super.onInit();
    ever<String?>(projects.selectedId, (_) => load());
    load();
  }

  Future<void> load() async {
    final pid = projectId;
    if (pid == null) {
      tasks.clear();
      selectedId.value = null;
      return;
    }
    final list = await AppServices.I.tasksStore(pid).list();
    tasks.assignAll(list);
    if (selectedId.value == null && list.isNotEmpty) {
      selectedId.value = list.first.id;
    }
  }

  Task? get selected {
    final id = selectedId.value;
    if (id == null) {
      return null;
    }
    return tasks.firstWhereOrNull((t) => t.id == id);
  }

  Future<Task> _validateAndNormalizeOrThrow(Task task) async {
    final pid = projectId;
    if (pid == null) {
      return task;
    }

    final trimmedName = task.name.trim();
    if (trimmedName.isEmpty) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '名称不能为空',
        message: '请填写任务名称。',
        suggestion: '例如：部署 / 升级 / 回滚。',
      );
    }

    final normalizedSlots = task.fileSlots
        .map(
          (s) => FileSlot(
            name: s.name.trim(),
            required: s.required,
            multiple: s.multiple,
          ),
        )
        .toList(growable: false);

    final names = <String>{};
    for (final s in normalizedSlots) {
      if (s.name.isEmpty || !_slotNameRe.hasMatch(s.name)) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: '槽位名不合法',
          message: '槽位名仅支持字母/数字/下划线。',
          suggestion: '命名规范：`[a-zA-Z0-9_]+`。',
        );
      }
      if (!names.add(s.name)) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: '槽位名重复',
          message: '同一个任务内不允许出现重复的槽位名。',
          suggestion: '修改槽位名后重试。',
        );
      }
    }

    final metas = await AppServices.I.playbooksStore(pid).listMeta();
    if (metas.every((p) => p.id != task.playbookId)) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: 'Playbook 不存在',
        message: '所选 Playbook 不存在或已被删除。',
        suggestion: '重新选择 Playbook，或先创建 Playbook。',
      );
    }

    return task.copyWith(
      name: trimmedName,
      description: task.description.trim(),
      fileSlots: normalizedSlots,
    );
  }

  Future<void> upsert(Task task) async {
    final pid = projectId;
    if (pid == null) {
      return;
    }
    final normalized = await _validateAndNormalizeOrThrow(task);
    await AppServices.I.tasksStore(pid).upsert(normalized);
    _logger.info(
      'tasks.upsert',
      data: {'project_id': pid, 'id': normalized.id},
    );
    await load();
    selectedId.value = normalized.id;
  }

  Future<void> deleteSelected() async {
    final pid = projectId;
    final id = selectedId.value;
    if (pid == null || id == null) {
      return;
    }

    final batches = await AppServices.I.batchesStore(pid).list();
    final usedBy = batches.where((b) => b.taskOrder.contains(id)).toList();
    if (usedBy.isNotEmpty) {
      final lines = usedBy
          .map((b) => '- ${b.name} (${b.id.substring(0, 8)})')
          .join('\n');
      throw AppException(
        code: AppErrorCode.validation,
        title: '任务被批次引用',
        message: '该任务正在被以下批次引用，无法删除：\n$lines',
        suggestion: '先在批次中移除该任务，或删除相关批次后再删除任务。',
      );
    }

    await AppServices.I.tasksStore(pid).delete(id);
    _logger.info('tasks.deleted', data: {'project_id': pid, 'id': id});
    selectedId.value = null;
    await load();
  }
}
