import 'dart:io';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;

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
  static final RegExp _varNameRe = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  static final RegExp _varTemplateRe = RegExp(
    r'\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}',
  );
  static const Set<String> _reservedVarNames = {
    // Reserved by run_engine vars json.
    'run_id',
    'run_dir',
    'files',
    'files_by_item',
    'task',
    'task_item',
    'task_files',
  };

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

    if (task.type != TaskType.ansiblePlaybook &&
        task.type != TaskType.localScript) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '任务类型不合法',
        message: '未知的任务类型(type)。',
        suggestion: '请重新创建任务。',
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
    if (task.type == TaskType.ansiblePlaybook) {
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
    }

    final normalizedVars = <TaskVariable>[];
    final varNames = <String>{};
    for (final v in task.variables) {
      final name = v.name.trim();
      if (name.isEmpty || !_varNameRe.hasMatch(name)) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: '变量名不合法',
          message: '变量名仅支持字母/数字/下划线，且必须以字母/下划线开头。',
          suggestion: '命名规范：`[A-Za-z_][A-Za-z0-9_]*`。',
        );
      }
      if (_reservedVarNames.contains(name)) {
        throw AppException(
          code: AppErrorCode.validation,
          title: '变量名被占用',
          message: '变量名 `$name` 为系统保留字段，不能使用。',
          suggestion: '请修改变量名后重试。',
        );
      }
      if (!varNames.add(name)) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: '变量名重复',
          message: '同一个任务内不允许出现重复的变量名。',
          suggestion: '修改变量名后重试。',
        );
      }
      normalizedVars.add(
        TaskVariable(
          name: name,
          description: v.description.trim(),
          defaultValue: v.defaultValue,
          required: v.required,
        ),
      );
    }

    final normalizedOutputs = <TaskOutput>[];
    final outputNames = <String>{};
    if (task.type == TaskType.localScript) {
      for (final o in task.outputs) {
        final name = o.name.trim();
        final path = o.path.trim();
        if (name.isEmpty || !_slotNameRe.hasMatch(name)) {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '产物名不合法',
            message: '产物名仅支持字母/数字/下划线。',
            suggestion: '请使用字母/数字/下划线组合。',
          );
        }
        if (!outputNames.add(name)) {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '产物名重复',
            message: '同一个脚本任务内不允许出现重复的产物名。',
            suggestion: '修改产物名后重试。',
          );
        }
        final hasTemplate = _varTemplateRe.hasMatch(path);
        if (path.isEmpty || (!p.isAbsolute(path) && !hasTemplate)) {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '产物路径不合法',
            message: '产物路径必须为绝对路径或可解析的变量模板。',
            suggestion: r'请填写绝对路径，或使用形如 ${output_path} 的变量模板。',
          );
        }
        normalizedOutputs.add(TaskOutput(name: name, path: path));
      }
    }

    String? playbookId = task.playbookId;
    TaskScript? script = task.script;
    List<FileSlot> slots = normalizedSlots;
    if (task.type == TaskType.ansiblePlaybook) {
      if (playbookId == null || playbookId.trim().isEmpty) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: '未绑定 Playbook',
          message: 'Ansible Playbook 任务必须选择一个 Playbook。',
          suggestion: '在任务编辑中绑定 Playbook 后重试。',
        );
      }
      final metas = await AppServices.I.playbooksStore(pid).listMeta();
      if (metas.every((p) => p.id != playbookId)) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: 'Playbook 不存在',
          message: '所选 Playbook 不存在或已被删除。',
          suggestion: '重新选择 Playbook，或先创建 Playbook。',
        );
      }
    } else {
      // local_script
      playbookId = null;
      slots = const <FileSlot>[];
      if (script == null) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: '脚本不能为空',
          message: '脚本任务必须填写脚本内容。',
          suggestion: '填写 bash/bat 脚本后重试。',
        );
      }
      if (script.content.trim().isEmpty) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: '脚本不能为空',
          message: '脚本任务必须填写脚本内容。',
          suggestion: '填写 bash/bat 脚本后重试。',
        );
      }
      var shell = script.shell.trim().isEmpty ? 'bash' : script.shell.trim();
      if (shell == 'sh') shell = 'bash';
      if (Platform.isWindows) {
        if (shell != 'bat') {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '脚本解释器不支持',
            message: 'Windows 本地脚本仅支持 bat。',
            suggestion: '请将脚本解释器切换为 bat。',
          );
        }
      } else {
        if (shell != 'bash') {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '脚本解释器不支持',
            message: 'Linux 本地脚本仅支持 bash。',
            suggestion: '请将脚本解释器切换为 bash。',
          );
        }
      }
      script = script.copyWith(shell: shell);
    }

    return task.copyWith(
      name: trimmedName,
      description: task.description.trim(),
      playbookId: playbookId,
      script: script,
      fileSlots: slots,
      variables: normalizedVars,
      outputs: normalizedOutputs,
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
    final usedBy = batches
        .where(
          (b) =>
              b.taskItems.any((i) => i.taskId == id) ||
              (b.taskItems.isEmpty && b.taskOrder.contains(id)),
        )
        .toList();
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
