import 'package:flutter/material.dart' as m;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../../model/file_slot.dart';
import '../../../model/playbook_meta.dart';
import '../../../model/task.dart';
import '../../../services/app_services.dart';
import '../../../services/core/app_error.dart';
import '../../controllers/playbooks_controller.dart';
import '../../controllers/tasks_controller.dart';
import '../../widgets/app_error_dialog.dart';
import '../../widgets/project_guard.dart';
import '../../utils/layout_metrics.dart';

class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.put(TasksController());
    final playbooks = Get.put(PlaybooksController());

    return ProjectGuard(
      child: Padding(
        padding: EdgeInsets.all(16.r),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final leftWidth = masterDetailLeftWidth(
              constraints,
              min: 340,
              max: 520,
              ratio: 0.36,
            );
            return Row(
              children: [
                SizedBox(
                  width: leftWidth,
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(12.r),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text('任务').p()),
                              Obx(() {
                                final canCreate =
                                    playbooks.playbooks.isNotEmpty;
                                return PrimaryButton(
                                  density: ButtonDensity.icon,
                                  onPressed: !canCreate
                                      ? null
                                      : () async {
                                          final created =
                                              await showDialog<Task>(
                                                context: context,
                                                builder: (context) =>
                                                    _TaskEditDialog(
                                                      initial: null,
                                                      playbooks:
                                                          playbooks.playbooks,
                                                    ),
                                              );
                                          if (created == null) return;
                                          try {
                                            await controller.upsert(created);
                                          } on AppException catch (e) {
                                            if (context.mounted) {
                                              await showAppErrorDialog(
                                                context,
                                                e,
                                              );
                                            }
                                          }
                                        },
                                  child: const Icon(Icons.add),
                                );
                              }),
                            ],
                          ),
                          Obx(() {
                            if (playbooks.playbooks.isNotEmpty) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: EdgeInsets.only(top: 8.h),
                              child: const Text(
                                '提示：请先创建 Playbook，才能新增任务。',
                              ).muted(),
                            );
                          }),
                          SizedBox(height: 12.h),
                          Expanded(
                            child: Obx(() {
                              final items = controller.tasks;
                              if (items.isEmpty) {
                                return const Center(child: Text('暂无任务'));
                              }
                              return m.ListView.builder(
                                itemCount: items.length,
                                itemBuilder: (context, i) {
                                  final t = items[i];
                                  final selected =
                                      controller.selectedId.value == t.id;
                                  final pb = playbooks.playbooks
                                      .firstWhereOrNull(
                                        (p) => p.id == t.playbookId,
                                      );
                                  final slotText = t.fileSlots.isEmpty
                                      ? '槽位: 无'
                                      : '槽位: ${t.fileSlots.length}';
                                  return m.ListTile(
                                    selected: selected,
                                    title: Text(t.name),
                                    subtitle: Text(
                                      pb == null
                                          ? 'Playbook: 未找到 · $slotText'
                                          : 'Playbook: ${pb.name} · $slotText',
                                    ).muted(),
                                    onTap: () =>
                                        controller.selectedId.value = t.id,
                                  );
                                },
                              );
                            }),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 16.w),
                Expanded(
                  child: Obx(() {
                    final t = controller.selected;
                    if (t == null) {
                      return const Card(
                        child: Center(child: Text('选择一个任务查看详情')),
                      );
                    }
                    final pb = playbooks.playbooks.firstWhereOrNull(
                      (p) => p.id == t.playbookId,
                    );
                    return _TaskDetail(task: t, playbook: pb);
                  }),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TaskDetail extends StatelessWidget {
  final Task task;
  final PlaybookMeta? playbook;

  const _TaskDetail({required this.task, required this.playbook});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<TasksController>();
    final playbooks = Get.find<PlaybooksController>();
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.r),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(task.name).h2()),
                GhostButton(
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
                  child: const Text('编辑'),
                ),
                SizedBox(width: 8.w),
                DestructiveButton(
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
                  child: const Text('删除'),
                ),
              ],
            ),
            SizedBox(height: 12.h),
            Text('ID: ${task.id}').mono(),
            SizedBox(height: 6.h),
            Text('Playbook: ${playbook?.name ?? '未找到'}').mono(),
            SizedBox(height: 12.h),
            Text('说明').p(),
            Text(task.description.isEmpty ? '—' : task.description).muted(),
            SizedBox(height: 16.h),
            Text('文件槽位').p(),
            SizedBox(height: 8.h),
            Expanded(
              child: task.fileSlots.isEmpty
                  ? const Text('无').muted()
                  : ListView.builder(
                      itemCount: task.fileSlots.length,
                      itemBuilder: (context, i) {
                        final s = task.fileSlots[i];
                        return Padding(
                          padding: EdgeInsets.symmetric(vertical: 6.h),
                          child: Row(
                            children: [
                              Expanded(child: Text(s.name).mono()),
                              SizedBox(width: 12.w),
                              Text(s.required ? '必选' : '可选').muted(),
                              SizedBox(width: 12.w),
                              Text(s.multiple ? '多文件' : '单文件').muted(),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
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
  final List<FileSlot> _slots = <FileSlot>[];

  String? _playbookId;

  static final RegExp _slotNameRe = RegExp(r'^[A-Za-z0-9_]+$');

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    if (i != null) {
      _name.text = i.name;
      _desc.text = i.description;
      _playbookId = i.playbookId;
      _slots.addAll(i.fileSlots);
    } else if (widget.playbooks.isNotEmpty) {
      _playbookId = widget.playbooks.first.id;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
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

  void _validateTaskOrThrow({
    required String name,
    required String playbookId,
  }) {
    if (name.isEmpty) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '名称不能为空',
        message: '请填写任务名称。',
        suggestion: '例如：部署 / 升级 / 回滚。',
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
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.initial;
    return AlertDialog(
      title: Text(initial == null ? '新增任务' : '编辑任务'),
      content: SizedBox(
        width: 560.w,
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
            if (widget.playbooks.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: const Text('暂无 Playbook，请先到 Playbook 页面创建。').muted(),
              )
            else
              m.DropdownButtonFormField<String>(
                key: ValueKey(_playbookId),
                initialValue: _playbookId,
                decoration: const m.InputDecoration(labelText: '绑定 Playbook'),
                items: widget.playbooks
                    .map(
                      (p) =>
                          m.DropdownMenuItem(value: p.id, child: Text(p.name)),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _playbookId = v),
              ),
            SizedBox(height: 16.h),
            Row(
              children: [
                const Expanded(child: Text('文件槽位')),
                OutlineButton(onPressed: _addSlot, child: const Text('新增槽位')),
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
                            onPressed: () => setState(() => _slots.removeAt(i)),
                            child: const Icon(Icons.close),
                          ),
                        );
                      },
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
          onPressed: widget.playbooks.isEmpty
              ? null
              : () async {
                  final name = _name.text.trim();
                  final pb = _playbookId;
                  if (pb == null) return;
                  try {
                    _validateTaskOrThrow(name: name, playbookId: pb);
                    if (!context.mounted) return;
                    Navigator.of(context).pop(
                      Task(
                        id: initial?.id ?? AppServices.I.uuid.v4(),
                        name: name,
                        description: _desc.text.trim(),
                        playbookId: pb,
                        fileSlots: List<FileSlot>.from(_slots),
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
