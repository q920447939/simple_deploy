import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' as m;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../../model/file_slot.dart';
import '../../../model/playbook_meta.dart';
import '../../../model/task.dart';
import '../../../model/task_template.dart';
import '../../../services/app_services.dart';
import '../../../services/core/app_error.dart';
import '../../../services/templates/task_template_store.dart';
import '../../controllers/playbooks_controller.dart';
import '../../controllers/tasks_controller.dart';
import '../../widgets/app_error_dialog.dart';
import '../../widgets/project_guard.dart';

class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Inject controllers
    final controller = Get.put(TasksController());
    Get.put(PlaybooksController());

    return ProjectGuard(
      child: Scaffold(
        child: Row(
          children: [
            // Sidebar: Fixed width
            SizedBox(width: 320.w, child: const _TaskSidebar()),
            const VerticalDivider(width: 1),
            // Main Content
            Expanded(
              child: Obx(() {
                final t = controller.selected;
                if (t == null) {
                  return const Center(child: Text('请选择一个任务查看详情'));
                }
                return _TaskDetail(task: t);
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _TemplatePickDialog extends StatelessWidget {
  final List<TaskTemplate> templates;

  const _TemplatePickDialog({required this.templates});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择任务模板'),
      content: SizedBox(
        width: 560.w,
        height: 420.h,
        child: ListView.separated(
          itemCount: templates.length,
          separatorBuilder: (context, index) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final t = templates[i];
            return m.ListTile(
              title: Text(t.name),
              subtitle: Text(t.description).muted(),
              trailing: Text(
                t.isAnsiblePlaybook ? 'Playbook' : 'Script',
              ).muted(),
              onTap: () => Navigator.of(context).pop(t),
            );
          },
        ),
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class _TaskSidebar extends StatelessWidget {
  const _TaskSidebar();

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<TasksController>();
    final playbooks = Get.find<PlaybooksController>();

    Future<void> importTaskFromClipboard() async {
      final pid = controller.projectId;
      if (pid == null) return;
      try {
        final data = await Clipboard.getData('text/plain');
        final text = (data?.text ?? '').trim();
        if (text.isEmpty) {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '剪贴板为空',
            message: '未读取到剪贴板文本。',
            suggestion: '先在其他项目中导出任务到剪贴板，再回来导入。',
          );
        }
        final raw = jsonDecode(text);
        if (raw is! Map) {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '导入失败',
            message: '剪贴板内容不是合法的 JSON 对象。',
            suggestion: '请确认复制的是任务导出的 JSON。',
          );
        }
        final format = raw['format'];
        if (format != 'simple_deploy.task.v2') {
          throw AppException(
            code: AppErrorCode.validation,
            title: '导入失败',
            message: '不支持的导入格式：$format',
            suggestion: '请使用同版本导出的任务 JSON。',
          );
        }
        final taskRaw = raw['task'];
        if (taskRaw is! Map) {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '导入失败',
            message: '缺少 task 字段。',
            suggestion: '请确认复制的是任务导出的 JSON。',
          );
        }

        final imported = Task.fromJson(taskRaw.cast<String, Object?>());

        String? newPlaybookId;
        if (imported.isAnsiblePlaybook) {
          final pb = raw['playbook'];
          if (pb is! Map) {
            throw const AppException(
              code: AppErrorCode.validation,
              title: '导入失败',
              message: 'Playbook 任务必须包含 playbook 字段。',
              suggestion: '请在导出时选择“包含 Playbook”。',
            );
          }
          final metaRaw = pb['meta'];
          final textRaw = pb['text'];
          if (metaRaw is! Map || textRaw is! String) {
            throw const AppException(
              code: AppErrorCode.validation,
              title: '导入失败',
              message: 'playbook.meta 或 playbook.text 缺失/不合法。',
              suggestion: '请重新导出后再导入。',
            );
          }
          final srcMeta = PlaybookMeta.fromJson(
            metaRaw.cast<String, Object?>(),
          );
          final newId = AppServices.I.uuid.v4();
          final now = DateTime.now();
          final ext = srcMeta.relativePath.toLowerCase().endsWith('.yaml')
              ? '.yaml'
              : '.yml';
          final relativePath = 'playbooks/import_${newId.substring(0, 8)}$ext';
          final newMeta = PlaybookMeta(
            id: newId,
            name: '${srcMeta.name} (导入)',
            description: srcMeta.description,
            relativePath: relativePath,
            updatedAt: now,
          );
          final store = AppServices.I.playbooksStore(pid);
          await store.writePlaybookText(newMeta, textRaw);
          await store.upsertMeta(newMeta);
          newPlaybookId = newId;
          await playbooks.load();
        }

        final newTask = Task(
          id: AppServices.I.uuid.v4(),
          name: imported.name,
          description: imported.description,
          type: imported.type,
          playbookId: imported.isAnsiblePlaybook ? newPlaybookId : null,
          script: imported.script,
          fileSlots: imported.fileSlots,
          variables: imported.variables,
          outputs: imported.outputs,
        );
        await controller.upsert(newTask);
        if (context.mounted) {
          showToast(
            context: context,
            builder: (context, overlay) => Card(
              child: Padding(
                padding: EdgeInsets.all(12.r),
                child: const Text('导入成功（已写入当前项目）'),
              ),
            ),
          );
        }
      } on AppException catch (e) {
        if (context.mounted) {
          await showAppErrorDialog(context, e);
        }
      } on Object catch (e) {
        if (context.mounted) {
          await showAppErrorDialog(
            context,
            AppException(
              code: AppErrorCode.unknown,
              title: '导入失败',
              message: e.toString(),
              suggestion: '请检查剪贴板内容后重试。',
              cause: e,
            ),
          );
        }
      }
    }

    Future<void> createTaskFromTemplate() async {
      final pid = controller.projectId;
      if (pid == null) return;
      try {
        final store = TaskTemplateStore();
        final templates = await store.list();
        if (!context.mounted) return;
        if (templates.isEmpty) {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '无可用模板',
            message: '未找到可用的任务模板。',
            suggestion: '请检查 templates.json 是否存在或更新安装包。',
          );
        }
        final picked = await showDialog<TaskTemplate>(
          context: context,
          builder: (context) => _TemplatePickDialog(templates: templates),
        );
        if (picked == null) return;

        String? playbookId;
        TaskScript? script;
        if (picked.isAnsiblePlaybook) {
          final text = await store.readPlaybookText(picked);
          final newId = AppServices.I.uuid.v4();
          final now = DateTime.now();
          final ext =
              (picked.playbookPath ?? '').toLowerCase().endsWith('.yaml')
              ? '.yaml'
              : '.yml';
          final relativePath =
              'playbooks/template_${picked.id}_${newId.substring(0, 6)}$ext';
          final meta = PlaybookMeta(
            id: newId,
            name: picked.playbookName ?? picked.name,
            description: picked.playbookDescription ?? picked.description,
            relativePath: relativePath,
            updatedAt: now,
          );
          final pbStore = AppServices.I.playbooksStore(pid);
          await pbStore.writePlaybookText(meta, text);
          await pbStore.upsertMeta(meta);
          playbookId = newId;
          await playbooks.load();
        } else if (picked.isLocalScript) {
          script = picked.script;
          if (script == null) {
            throw const AppException(
              code: AppErrorCode.validation,
              title: '模板不完整',
              message: '脚本模板缺少脚本内容。',
              suggestion: '请更新模板索引或联系管理员。',
            );
          }
        }

        final task = Task(
          id: AppServices.I.uuid.v4(),
          name: picked.name,
          description: picked.description,
          type: picked.type,
          playbookId: playbookId,
          script: script,
          fileSlots: picked.fileSlots,
          variables: picked.variables,
          outputs: picked.outputs,
        );
        await controller.upsert(task);
        if (context.mounted) {
          showToast(
            context: context,
            builder: (context, overlay) => Card(
              child: Padding(
                padding: EdgeInsets.all(12.r),
                child: const Text('模板任务已创建'),
              ),
            ),
          );
        }
      } on AppException catch (e) {
        if (context.mounted) {
          await showAppErrorDialog(context, e);
        }
      } on Object catch (e) {
        if (context.mounted) {
          await showAppErrorDialog(
            context,
            AppException(
              code: AppErrorCode.unknown,
              title: '创建模板任务失败',
              message: e.toString(),
              suggestion: '请检查模板资源后重试。',
              cause: e,
            ),
          );
        }
      }
    }

    return Column(
      children: [
        // Sidebar Header
        Container(
          height: 50.h,
          padding: EdgeInsets.symmetric(horizontal: 12.w),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: m.Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '任务',
                  style: m.Theme.of(context).textTheme.titleMedium,
                ),
              ),
              GhostButton(
                density: ButtonDensity.icon,
                onPressed: () async {
                  final created = await showDialog<Task>(
                    context: context,
                    builder: (context) => _TaskEditDialog(
                      initial: null,
                      playbooks: playbooks.playbooks,
                    ),
                  );
                  if (created == null) return;
                  try {
                    await controller.upsert(created);
                  } on AppException catch (e) {
                    if (context.mounted) {
                      await showAppErrorDialog(context, e);
                    }
                  }
                },
                child: const Icon(Icons.add, size: 18),
              ),
              SizedBox(width: 4.w),
              GhostButton(
                density: ButtonDensity.icon,
                onPressed: createTaskFromTemplate,
                child: const Icon(Icons.auto_awesome, size: 16),
              ),
              SizedBox(width: 4.w),
              GhostButton(
                density: ButtonDensity.icon,
                onPressed: importTaskFromClipboard,
                child: const Icon(Icons.content_paste, size: 16),
              ),
            ],
          ),
        ),
        // Task List
        Expanded(
          child: Obx(() {
            final items = controller.tasks;
            if (items.isEmpty) {
              return const Center(child: Text('暂无任务'));
            }
            return m.ListView.separated(
              itemCount: items.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final t = items[i];
                final selected = controller.selectedId.value == t.id;
                final isLocal = t.isLocalScript;

                return m.Material(
                  color: selected
                      ? m.Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.05)
                      : Colors.transparent,
                  child: m.InkWell(
                    onTap: () => controller.selectedId.value = t.id,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12.w,
                        vertical: 10.h,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.name,
                            style: m.Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w500,
                                  color: selected
                                      ? m.Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                          ),
                          SizedBox(height: 4.h),
                          Row(
                            children: [
                              Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 4.w,
                                  vertical: 1.h,
                                ),
                                decoration: BoxDecoration(
                                  color: isLocal
                                      ? m.Colors.blue.withValues(alpha: 0.1)
                                      : m.Colors.orange.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(4.r),
                                ),
                                child: Text(
                                  isLocal ? 'Script' : 'Playbook',
                                  style: TextStyle(
                                    fontSize: 10.sp,
                                    color: isLocal
                                        ? m.Colors.blue
                                        : m.Colors.orange.shade800,
                                  ),
                                ),
                              ),
                              if (t.variables.isNotEmpty) ...[
                                SizedBox(width: 6.w),
                                Text(
                                  '${t.variables.length} Vars',
                                  style: m.Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        fontSize: 11.sp,
                                        color: m.Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.5),
                                      ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          }),
        ),
      ],
    );
  }
}

class _TaskDetail extends StatelessWidget {
  final Task task;

  const _TaskDetail({required this.task});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<TasksController>();
    final playbooks = Get.find<PlaybooksController>();
    final playbook = playbooks.playbooks.firstWhereOrNull(
      (p) => p.id == task.playbookId,
    );

    final labelStyle = TextStyle(
      color: m.Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
      fontSize: 13.sp,
    );
    final valueStyle = TextStyle(
      fontFamily: 'GeistMono',
      fontSize: 13.sp,
      height: 1.5,
    );

    Widget infoRow(String label, Widget content) {
      return Padding(
        padding: EdgeInsets.only(bottom: 12.h),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 80.w,
              child: Text(label, style: labelStyle),
            ),
            Expanded(child: content),
          ],
        ),
      );
    }

    Widget infoText(String label, String value) {
      return infoRow(label, SelectableText(value, style: valueStyle));
    }

    Future<void> duplicateTask() async {
      final seed = Task(
        id: AppServices.I.uuid.v4(),
        name: '${task.name} (复制)',
        description: task.description,
        type: task.type,
        playbookId: task.playbookId,
        script: task.script,
        fileSlots: List<FileSlot>.from(task.fileSlots),
        variables: List<TaskVariable>.from(task.variables),
        outputs: List<TaskOutput>.from(task.outputs),
      );
      final created = await showDialog<Task>(
        context: context,
        builder: (context) =>
            _TaskEditDialog(initial: seed, playbooks: playbooks.playbooks),
      );
      if (created == null) return;
      try {
        await controller.upsert(created);
      } on AppException catch (e) {
        if (context.mounted) {
          await showAppErrorDialog(context, e);
        }
      }
    }

    Future<void> exportToClipboard() async {
      final pid = controller.projectId;
      if (pid == null) return;
      try {
        Map<String, Object?>? playbookPayload;
        if (task.isAnsiblePlaybook) {
          final meta = playbook;
          if (meta == null) {
            throw const AppException(
              code: AppErrorCode.validation,
              title: '导出失败',
              message: '该任务绑定的 Playbook 未找到。',
              suggestion: '请先修复任务的 Playbook 绑定后再导出。',
            );
          }
          final text = await AppServices.I
              .playbooksStore(pid)
              .readPlaybookText(meta);
          playbookPayload = {'meta': meta.toJson(), 'text': text};
        }
        final payload = <String, Object?>{
          'format': 'simple_deploy.task.v2',
          'exported_at': DateTime.now().toIso8601String(),
          'task': task.toJson(),
          'playbook': playbookPayload,
        };
        final pretty = const JsonEncoder.withIndent('  ').convert(payload);
        await Clipboard.setData(ClipboardData(text: '$pretty\n'));
        if (context.mounted) {
          showToast(
            context: context,
            builder: (context, overlay) => Card(
              child: Padding(
                padding: EdgeInsets.all(12.r),
                child: const Text('已导出到剪贴板'),
              ),
            ),
          );
        }
      } on AppException catch (e) {
        if (context.mounted) {
          await showAppErrorDialog(context, e);
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Detail Header
        Container(
          height: 50.h,
          padding: EdgeInsets.symmetric(horizontal: 24.w),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: m.Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  task.name,
                  style: m.Theme.of(context).textTheme.titleLarge,
                ),
              ),
              GhostButton(
                density: ButtonDensity.icon,
                onPressed: () async {
                  final updated = await showDialog<Task>(
                    context: context,
                    builder: (context) => _TaskEditDialog(
                      initial: task,
                      playbooks: playbooks.playbooks,
                    ),
                  );
                  if (updated == null) return;
                  try {
                    await controller.upsert(updated);
                  } on AppException catch (e) {
                    if (context.mounted) {
                      await showAppErrorDialog(context, e);
                    }
                  }
                },
                child: const Icon(Icons.edit, size: 16),
              ),
              SizedBox(width: 8.w),
              GhostButton(
                density: ButtonDensity.icon,
                onPressed: duplicateTask,
                child: const Icon(Icons.copy, size: 16),
              ),
              SizedBox(width: 8.w),
              OutlineButton(
                density: ButtonDensity.icon,
                onPressed: exportToClipboard,
                child: const Icon(Icons.ios_share, size: 16),
              ),
              SizedBox(width: 8.w),
              DestructiveButton(
                density: ButtonDensity.icon,
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('删除任务？'),
                      content: Text('将删除：${task.name}'),
                      actions: [
                        OutlineButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('取消'),
                        ),
                        DestructiveButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('删除'),
                        ),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  try {
                    await controller.deleteSelected();
                  } on AppException catch (e) {
                    if (context.mounted) {
                      await showAppErrorDialog(context, e);
                    }
                  }
                },
                child: const Icon(Icons.delete_outline, size: 16),
              ),
            ],
          ),
        ),
        // Content
        Expanded(
          child: m.SingleChildScrollView(
            padding: EdgeInsets.all(24.r),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('基本信息', style: m.Theme.of(context).textTheme.titleMedium),
                SizedBox(height: 16.h),
                infoText('ID', task.id),
                infoText(
                  '类型',
                  task.isLocalScript ? '脚本任务 (Local)' : 'Playbook 任务 (Control)',
                ),
                if (task.isAnsiblePlaybook)
                  infoText('Playbook', playbook?.name ?? '（未找到，请修复）'),
                if (task.isLocalScript)
                  infoText('解释器', task.script?.shell ?? 'bash'),
                infoText(
                  '说明',
                  task.description.isEmpty ? '—' : task.description,
                ),

                SizedBox(height: 32.h),
                Text('配置详情', style: m.Theme.of(context).textTheme.titleMedium),
                SizedBox(height: 16.h),
                if (task.isLocalScript) ...[
                  infoRow(
                    '脚本内容',
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(12.r),
                      decoration: BoxDecoration(
                        color: m.Theme.of(context).colorScheme.surface,
                        border: Border.all(
                          color: m.Theme.of(context).dividerColor,
                        ),
                        borderRadius: BorderRadius.circular(6.r),
                      ),
                      child: SelectableText(
                        task.script?.content.trim() ?? '',
                        style: valueStyle.copyWith(fontSize: 12.sp),
                      ),
                    ),
                  ),
                  SizedBox(height: 16.h),
                  infoRow(
                    '产物',
                    task.outputs.isEmpty
                        ? Text(
                            '无',
                            style: valueStyle.copyWith(color: m.Colors.grey),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: task.outputs.map((o) {
                              return Padding(
                                padding: EdgeInsets.only(bottom: 4.h),
                                child: Text(
                                  '${o.name} = ${o.path}',
                                  style: valueStyle,
                                ),
                              );
                            }).toList(),
                          ),
                  ),
                ],
                if (task.isAnsiblePlaybook && task.fileSlots.isNotEmpty) ...[
                  infoRow(
                    '文件槽位',
                    Wrap(
                      spacing: 8.w,
                      runSpacing: 8.h,
                      children: task.fileSlots.map((s) {
                        return Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8.w,
                            vertical: 4.h,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: m.Theme.of(context).dividerColor,
                            ),
                            borderRadius: BorderRadius.circular(4.r),
                          ),
                          child: Text(
                            '${s.name}${s.required ? "*" : ""} (${s.multiple ? "N" : "1"})',
                            style: valueStyle.copyWith(fontSize: 12.sp),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
                SizedBox(height: 16.h),
                infoRow(
                  '输入变量',
                  task.variables.isEmpty
                      ? Text(
                          '无',
                          style: valueStyle.copyWith(color: m.Colors.grey),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: task.variables.map((v) {
                            return Padding(
                              padding: EdgeInsets.only(bottom: 4.h),
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: v.name,
                                      style: valueStyle.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (v.required)
                                      TextSpan(
                                        text: '*',
                                        style: valueStyle.copyWith(
                                          color: m.Colors.red,
                                        ),
                                      ),
                                    TextSpan(
                                      text: '  = ${v.defaultValue}',
                                      style: valueStyle.copyWith(
                                        color: m.Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TaskEditDialog extends StatefulWidget {
  final Task? initial;
  final List<PlaybookMeta> playbooks;

  const _TaskEditDialog({required this.initial, required this.playbooks});

  @override
  State<_TaskEditDialog> createState() => _TaskEditDialogState();
}

class _TaskEditDialogState extends State<_TaskEditDialog> {
  final m.TextEditingController _name = m.TextEditingController();
  final m.TextEditingController _desc = m.TextEditingController();
  final m.TextEditingController _script = m.TextEditingController();

  final List<FileSlot> _slots = <FileSlot>[];
  final List<TaskVariable> _vars = <TaskVariable>[];
  final List<TaskOutput> _outputs = <TaskOutput>[];

  String _type = TaskType.ansiblePlaybook;
  String? _playbookId;
  String _shell = 'bash';

  static final RegExp _slotNameRe = RegExp(r'^[A-Za-z0-9_]+$');
  static final RegExp _varNameRe = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  static const Set<String> _reservedVarNames = {
    'run_id',
    'run_dir',
    'files',
    'files_by_item',
    'task',
    'task_item',
    'task_files',
  };

  @override
  void initState() {
    super.initState();
    final defaultShell = Platform.isWindows ? 'bat' : 'bash';
    _shell = defaultShell;
    final i = widget.initial;
    if (i != null) {
      _name.text = i.name;
      _desc.text = i.description;
      _type = i.type;
      _playbookId = i.playbookId;
      _slots.addAll(i.fileSlots);
      _vars.addAll(i.variables);
      _outputs.addAll(i.outputs);
      final s = i.script;
      if (s != null) {
        _shell = s.shell;
        if (_shell == 'sh') _shell = 'bash';
        final allowed = Platform.isWindows ? const ['bat'] : const ['bash'];
        if (!allowed.contains(_shell)) {
          _shell = defaultShell;
        }
        _script.text = s.content;
      }
    } else {
      _type = widget.playbooks.isEmpty
          ? TaskType.localScript
          : TaskType.ansiblePlaybook;
      if (widget.playbooks.isNotEmpty) {
        _playbookId = widget.playbooks.first.id;
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _script.dispose();
    super.dispose();
  }

  Future<void> _addSlot() async {
    final r = await showDialog<FileSlot>(
      context: context,
      builder: (context) => const _FileSlotDialog(),
    );
    if (r == null) return;
    if (!mounted) return;
    if (_slots.any((s) => s.name == r.name)) {
      await showAppErrorDialog(
        context,
        const AppException(
          code: AppErrorCode.validation,
          title: '槽位名重复',
          message: '同一个任务内不允许出现重复的槽位名。',
          suggestion: '修改槽位名（建议：artifact / config / package）。',
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _slots.add(r));
  }

  Future<void> _addVar() async {
    final r = await showDialog<TaskVariable>(
      context: context,
      builder: (context) => const _TaskVarDialog(),
    );
    if (r == null) return;
    if (!mounted) return;

    final name = r.name.trim();
    if (name.isEmpty || !_varNameRe.hasMatch(name)) {
      await showAppErrorDialog(
        context,
        const AppException(
          code: AppErrorCode.validation,
          title: '变量名不合法',
          message: '变量名仅支持字母/数字/下划线，且必须以字母/下划线开头。',
          suggestion: '命名规范：`[A-Za-z_][A-Za-z0-9_]*`。',
        ),
      );
      return;
    }
    if (_reservedVarNames.contains(name)) {
      await showAppErrorDialog(
        context,
        AppException(
          code: AppErrorCode.validation,
          title: '变量名被占用',
          message: '变量名 `$name` 为系统保留字段，不能使用。',
          suggestion: '请修改变量名后重试。',
        ),
      );
      return;
    }
    if (_vars.any((v) => v.name == name)) {
      await showAppErrorDialog(
        context,
        const AppException(
          code: AppErrorCode.validation,
          title: '变量名重复',
          message: '同一个任务内不允许出现重复的变量名。',
          suggestion: '修改变量名后重试。',
        ),
      );
      return;
    }

    setState(() {
      _vars.add(r.copyWith(name: name, description: r.description.trim()));
    });
  }

  Future<void> _addOutput() async {
    final r = await showDialog<TaskOutput>(
      context: context,
      builder: (context) => const _TaskOutputDialog(),
    );
    if (r == null) return;
    if (!mounted) return;

    final name = r.name.trim();
    final path = r.path.trim();
    if (name.isEmpty || !_slotNameRe.hasMatch(name)) {
      await showAppErrorDialog(
        context,
        const AppException(
          code: AppErrorCode.validation,
          title: '产物名不合法',
          message: '产物名仅支持字母/数字/下划线。',
          suggestion: '请使用字母/数字/下划线组合。',
        ),
      );
      return;
    }
    if (!p.isAbsolute(path)) {
      await showAppErrorDialog(
        context,
        const AppException(
          code: AppErrorCode.validation,
          title: '产物路径不合法',
          message: '产物路径必须为绝对路径。',
          suggestion: '请填写绝对路径（如 /abs/path/file.jar）。',
        ),
      );
      return;
    }
    if (_outputs.any((o) => o.name == name)) {
      await showAppErrorDialog(
        context,
        const AppException(
          code: AppErrorCode.validation,
          title: '产物名重复',
          message: '同一个任务内不允许出现重复的产物名。',
          suggestion: '修改产物名后重试。',
        ),
      );
      return;
    }

    setState(() {
      _outputs.add(TaskOutput(name: name, path: path));
    });
  }

  void _validateTaskOrThrow({
    required String name,
    required String type,
    required String? playbookId,
  }) {
    if (name.isEmpty) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '名称不能为空',
        message: '请填写任务名称。',
        suggestion: '例如：部署 / 升级 / 回滚。',
      );
    }
    if (type == TaskType.ansiblePlaybook) {
      if (playbookId == null) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: '未绑定 Playbook',
          message: 'Ansible Playbook 任务必须选择一个 Playbook。',
          suggestion: '在任务编辑中绑定 Playbook 后重试。',
        );
      }
      if (widget.playbooks.every((p) => p.id != playbookId)) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: 'Playbook 不存在',
          message: '所选 Playbook 不存在或已被删除。',
          suggestion: '重新选择 Playbook，或先创建 Playbook。',
        );
      }
      for (final s in _slots) {
        if (s.name.trim().isEmpty || !_slotNameRe.hasMatch(s.name)) {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '槽位名不合法',
            message: '槽位名仅支持字母/数字/下划线。',
            suggestion: '命名规范：`[a-zA-Z0-9_]+`。',
          );
        }
      }
    } else {
      if (_script.text.trim().isEmpty) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: '脚本不能为空',
          message: '脚本任务必须填写脚本内容。',
          suggestion: '填写 bash/bat 脚本后重试。',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.initial;
    return AlertDialog(
      title: Text(initial == null ? '新增任务' : '编辑任务'),
      content: SizedBox(
        width: 680.w,
        child: m.ConstrainedBox(
          constraints: m.BoxConstraints(
            maxHeight: m.MediaQuery.of(context).size.height * 0.7,
          ),
          child: m.SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                m.TextField(
                  controller: _name,
                  decoration: const m.InputDecoration(labelText: '名称'),
                ),
                SizedBox(height: 12.h),
                m.TextField(
                  controller: _desc,
                  decoration: const m.InputDecoration(labelText: '描述（可选）'),
                ),
                SizedBox(height: 12.h),
                m.DropdownButtonFormField<String>(
                  key: ValueKey(_type),
                  initialValue: _type,
                  decoration: const m.InputDecoration(labelText: '类型'),
                  items: const [
                    m.DropdownMenuItem(
                      value: TaskType.ansiblePlaybook,
                      child: Text('Ansible Playbook（控制端执行）'),
                    ),
                    m.DropdownMenuItem(
                      value: TaskType.localScript,
                      child: Text('脚本任务（本地执行）'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _type = v;
                      if (_type == TaskType.localScript) {
                        _playbookId = null;
                        _slots.clear();
                        _outputs.clear();
                      }
                      if (_type == TaskType.ansiblePlaybook &&
                          _playbookId == null &&
                          widget.playbooks.isNotEmpty) {
                        _playbookId = widget.playbooks.first.id;
                        _outputs.clear();
                      }
                    });
                  },
                ),
                SizedBox(height: 12.h),
                if (widget.playbooks.isEmpty &&
                    _type == TaskType.ansiblePlaybook)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: const Text('暂无 Playbook，请先到 Playbook 页面创建。').muted(),
                  )
                else if (_type == TaskType.ansiblePlaybook)
                  m.DropdownButtonFormField<String>(
                    key: ValueKey(_playbookId),
                    initialValue: _playbookId,
                    decoration: const m.InputDecoration(
                      labelText: '绑定 Playbook',
                    ),
                    items: widget.playbooks
                        .map(
                          (p) => m.DropdownMenuItem(
                            value: p.id,
                            child: Text(p.name),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _playbookId = v),
                  ),
                if (_type == TaskType.localScript) ...[
                  SizedBox(height: 12.h),
                  m.DropdownButtonFormField<String>(
                    key: ValueKey(_shell),
                    initialValue: _shell,
                    decoration: const m.InputDecoration(labelText: '解释器'),
                    items: (Platform.isWindows ? const ['bat'] : const ['bash'])
                        .map(
                          (v) => m.DropdownMenuItem(value: v, child: Text(v)),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _shell = v ?? _shell),
                  ),
                  SizedBox(height: 12.h),
                  m.TextField(
                    controller: _script,
                    maxLines: 10,
                    decoration: const m.InputDecoration(
                      labelText: '脚本内容',
                      hintText:
                          '变量会以环境变量形式注入：SD_<var_name>；同时提供 SD_STAGE_DIR/SD_TASK_VARS_JSON 等。',
                    ),
                  ),
                ],
                SizedBox(height: 16.h),
                Row(
                  children: [
                    const Expanded(child: Text('变量')),
                    OutlineButton(
                      onPressed: _addVar,
                      child: const Text('新增变量'),
                    ),
                  ],
                ),
                SizedBox(height: 8.h),
                SizedBox(
                  height: 140.h,
                  child: _vars.isEmpty
                      ? const Center(child: Text('无'))
                      : m.ListView.builder(
                          itemCount: _vars.length,
                          itemBuilder: (context, i) {
                            final v = _vars[i];
                            final req = v.required ? '必填' : '可选';
                            final def = v.defaultValue.isEmpty
                                ? '默认: (空)'
                                : '默认: ${v.defaultValue}';
                            return m.ListTile(
                              title: Text(v.name).mono(),
                              subtitle: Text('$req · $def').muted(),
                              trailing: GhostButton(
                                density: ButtonDensity.icon,
                                onPressed: () =>
                                    setState(() => _vars.removeAt(i)),
                                child: const Icon(Icons.close),
                              ),
                            );
                          },
                        ),
                ),
                if (_type == TaskType.localScript) ...[
                  SizedBox(height: 16.h),
                  Row(
                    children: [
                      const Expanded(child: Text('产物')),
                      OutlineButton(
                        onPressed: _addOutput,
                        child: const Text('新增产物'),
                      ),
                    ],
                  ),
                  SizedBox(height: 8.h),
                  SizedBox(
                    height: 140.h,
                    child: _outputs.isEmpty
                        ? const Center(child: Text('无'))
                        : m.ListView.builder(
                            itemCount: _outputs.length,
                            itemBuilder: (context, i) {
                              final o = _outputs[i];
                              return m.ListTile(
                                title: Text(o.name).mono(),
                                subtitle: Text(o.path).muted(),
                                trailing: GhostButton(
                                  density: ButtonDensity.icon,
                                  onPressed: () =>
                                      setState(() => _outputs.removeAt(i)),
                                  child: const Icon(Icons.close),
                                ),
                              );
                            },
                          ),
                  ),
                ],
                if (_type == TaskType.ansiblePlaybook) ...[
                  SizedBox(height: 16.h),
                  Row(
                    children: [
                      const Expanded(child: Text('文件槽位')),
                      OutlineButton(
                        onPressed: _addSlot,
                        child: const Text('新增槽位'),
                      ),
                    ],
                  ),
                  SizedBox(height: 8.h),
                  SizedBox(
                    height: 160.h,
                    child: _slots.isEmpty
                        ? const Center(child: Text('无'))
                        : m.ListView.builder(
                            itemCount: _slots.length,
                            itemBuilder: (context, i) {
                              final s = _slots[i];
                              return m.ListTile(
                                title: Text(s.name),
                                subtitle: Text(
                                  '${s.required ? '必选' : '可选'} · ${s.multiple ? '多文件' : '单文件'}',
                                ).muted(),
                                trailing: GhostButton(
                                  density: ButtonDensity.icon,
                                  onPressed: () =>
                                      setState(() => _slots.removeAt(i)),
                                  child: const Icon(Icons.close),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        PrimaryButton(
          onPressed: () async {
            final name = _name.text.trim();
            try {
              _validateTaskOrThrow(
                name: name,
                type: _type,
                playbookId: _playbookId,
              );
              if (!context.mounted) return;
              Navigator.of(context).pop(
                Task(
                  id: initial?.id ?? AppServices.I.uuid.v4(),
                  name: name,
                  description: _desc.text.trim(),
                  type: _type,
                  playbookId: _type == TaskType.ansiblePlaybook
                      ? _playbookId
                      : null,
                  script: _type == TaskType.localScript
                      ? TaskScript(shell: _shell, content: _script.text)
                      : null,
                  fileSlots: _type == TaskType.ansiblePlaybook
                      ? List<FileSlot>.from(_slots)
                      : const <FileSlot>[],
                  variables: List<TaskVariable>.from(_vars),
                  outputs: _type == TaskType.localScript
                      ? List<TaskOutput>.from(_outputs)
                      : const <TaskOutput>[],
                ),
              );
            } on AppException catch (e) {
              if (context.mounted) {
                await showAppErrorDialog(context, e);
              }
            }
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _TaskVarDialog extends StatefulWidget {
  const _TaskVarDialog();

  @override
  State<_TaskVarDialog> createState() => _TaskVarDialogState();
}

class _TaskVarDialogState extends State<_TaskVarDialog> {
  final m.TextEditingController _name = m.TextEditingController();
  final m.TextEditingController _desc = m.TextEditingController();
  final m.TextEditingController _def = m.TextEditingController();
  bool _required = false;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _def.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新增变量'),
      content: SizedBox(
        width: 520.w,
        child: m.ConstrainedBox(
          constraints: m.BoxConstraints(
            maxHeight: m.MediaQuery.of(context).size.height * 0.6,
          ),
          child: m.SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                m.TextField(
                  controller: _name,
                  decoration: const m.InputDecoration(
                    labelText: '变量名',
                    hintText: '例如：version / package_name / env',
                  ),
                ),
                SizedBox(height: 8.h),
                m.TextField(
                  controller: _def,
                  decoration: const m.InputDecoration(labelText: '默认值（可选）'),
                ),
                SizedBox(height: 8.h),
                m.TextField(
                  controller: _desc,
                  decoration: const m.InputDecoration(labelText: '描述（可选）'),
                ),
                SizedBox(height: 8.h),
                m.CheckboxListTile(
                  value: _required,
                  onChanged: (v) => setState(() => _required = v ?? _required),
                  title: const Text('必填'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        PrimaryButton(
          onPressed: () {
            Navigator.of(context).pop(
              TaskVariable(
                name: _name.text.trim(),
                description: _desc.text.trim(),
                defaultValue: _def.text,
                required: _required,
              ),
            );
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _FileSlotDialog extends StatefulWidget {
  const _FileSlotDialog();

  @override
  State<_FileSlotDialog> createState() => _FileSlotDialogState();
}

class _FileSlotDialogState extends State<_FileSlotDialog> {
  final m.TextEditingController _name = m.TextEditingController();
  bool _required = false;
  bool _multiple = false;

  static final RegExp _slotNameRe = RegExp(r'^[A-Za-z0-9_]+$');

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新增文件槽位'),
      content: SizedBox(
        width: 520.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            m.TextField(
              controller: _name,
              decoration: const m.InputDecoration(
                labelText: '槽位名（slot_name）',
                hintText: '例如：artifact / config / package',
              ),
            ),
            SizedBox(height: 8.h),
            m.CheckboxListTile(
              value: _required,
              onChanged: (v) => setState(() => _required = v ?? _required),
              title: const Text('必选'),
            ),
            m.CheckboxListTile(
              value: _multiple,
              onChanged: (v) => setState(() => _multiple = v ?? _multiple),
              title: const Text('允许多文件'),
            ),
          ],
        ),
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        PrimaryButton(
          onPressed: () async {
            final name = _name.text.trim();
            if (name.isEmpty || !_slotNameRe.hasMatch(name)) {
              await showAppErrorDialog(
                context,
                const AppException(
                  code: AppErrorCode.validation,
                  title: '槽位名不合法',
                  message: '槽位名仅支持字母/数字/下划线。',
                  suggestion: '命名规范：`[a-zA-Z0-9_]+`。',
                ),
              );
              return;
            }
            if (!context.mounted) return;
            Navigator.of(context).pop(
              FileSlot(name: name, required: _required, multiple: _multiple),
            );
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _TaskOutputDialog extends StatefulWidget {
  const _TaskOutputDialog();

  @override
  State<_TaskOutputDialog> createState() => _TaskOutputDialogState();
}

class _TaskOutputDialogState extends State<_TaskOutputDialog> {
  final m.TextEditingController _name = m.TextEditingController();
  final m.TextEditingController _path = m.TextEditingController();

  static final RegExp _slotNameRe = RegExp(r'^[A-Za-z0-9_]+$');

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新增脚本产物'),
      content: SizedBox(
        width: 560.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            m.TextField(
              controller: _name,
              decoration: const m.InputDecoration(
                labelText: '产物名',
                hintText: '例如：artifact / package',
              ),
            ),
            SizedBox(height: 8.h),
            m.TextField(
              controller: _path,
              decoration: const m.InputDecoration(
                labelText: '产物绝对路径',
                hintText:
                    r'例如：/abs/path/app.jar、${output_path} 或 C:\path\app.jar',
              ),
            ),
          ],
        ),
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        PrimaryButton(
          onPressed: () async {
            final name = _name.text.trim();
            final path = _path.text.trim();
            if (name.isEmpty || !_slotNameRe.hasMatch(name)) {
              await showAppErrorDialog(
                context,
                const AppException(
                  code: AppErrorCode.validation,
                  title: '产物名不合法',
                  message: '产物名仅支持字母/数字/下划线。',
                  suggestion: '请使用字母/数字/下划线组合。',
                ),
              );
              return;
            }
            final hasTemplate = RegExp(
              r'\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}',
            ).hasMatch(path);
            if (!p.isAbsolute(path) && !hasTemplate) {
              await showAppErrorDialog(
                context,
                const AppException(
                  code: AppErrorCode.validation,
                  title: '产物路径不合法',
                  message: '产物路径必须为绝对路径或可解析的变量模板。',
                  suggestion: r'请填写绝对路径，或使用形如 ${output_path} 的变量模板。',
                ),
              );
              return;
            }
            if (!context.mounted) return;
            Navigator.of(context).pop(TaskOutput(name: name, path: path));
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
