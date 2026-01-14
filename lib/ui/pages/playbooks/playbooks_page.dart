import 'package:flutter/material.dart' as m;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:yaml/yaml.dart';

import '../../../model/playbook_meta.dart';
import '../../../services/core/app_error.dart';
import '../../controllers/playbooks_controller.dart';
import '../../widgets/app_error_dialog.dart';
import '../../widgets/confirm_dialogs.dart';
import '../../widgets/project_guard.dart';
import '../../utils/date_time_fmt.dart';
import '../../utils/layout_metrics.dart';

class PlaybooksPage extends StatelessWidget {
  const PlaybooksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.put(PlaybooksController());

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
                              Expanded(child: Text('Playbook').p()),
                              Obx(() {
                                final count = controller.bulkSelectedIds.length;
                                return GhostButton(
                                  density: ButtonDensity.icon,
                                  onPressed: count == 0
                                      ? null
                                      : () async {
                                          if (controller.dirty.value) {
                                            final ok = await confirmDiscardChanges(
                                              context,
                                              message:
                                                  '当前 Playbook 有未保存修改，批量删除将丢失这些修改。',
                                              discardLabel: '丢弃并继续',
                                            );
                                            if (!ok) return;
                                            controller.discardEdits();
                                          }
                                          if (!context.mounted) return;
                                          final ok = await showDialog<bool>(
                                            context: context,
                                            builder: (context) =>
                                                _BulkDeletePlaybooksDialog(
                                                  count: count,
                                                ),
                                          );
                                          if (ok != true) return;
                                          try {
                                            final ids = controller
                                                .bulkSelectedIds
                                                .toList(growable: false);
                                            await controller.deleteMany(ids);
                                          } on AppException catch (e) {
                                            if (context.mounted) {
                                              await showAppErrorDialog(
                                                context,
                                                e,
                                              );
                                            }
                                          }
                                        },
                                  child: const Icon(Icons.delete_outline),
                                );
                              }),
                              SizedBox(width: 8.w),
                              PrimaryButton(
                                density: ButtonDensity.icon,
                                onPressed: () async {
                                  if (controller.dirty.value) {
                                    final ok = await confirmDiscardChanges(
                                      context,
                                      message: '当前 Playbook 有未保存修改，新建将丢失这些修改。',
                                      discardLabel: '丢弃并新建',
                                    );
                                    if (!ok) return;
                                    if (!context.mounted) return;
                                    controller.discardEdits();
                                  }
                                  final created =
                                      await showDialog<_CreatePlaybookResult>(
                                        context: context,
                                        builder: (context) =>
                                            const _CreatePlaybookDialog(),
                                      );
                                  if (created == null) return;
                                  try {
                                    await controller.create(
                                      name: created.name,
                                      description: created.description,
                                      fileName: created.fileName,
                                    );
                                  } on AppException catch (e) {
                                    if (context.mounted) {
                                      await showAppErrorDialog(context, e);
                                    }
                                  }
                                },
                                child: const Icon(Icons.add),
                              ),
                            ],
                          ),
                          SizedBox(height: 12.h),
                          Expanded(
                            child: Obx(() {
                              final items = controller.playbooks;
                              if (items.isEmpty) {
                                return const Center(child: Text('暂无 Playbook'));
                              }
                              return m.ListView.builder(
                                itemCount: items.length,
                                itemBuilder: (context, i) {
                                  final p = items[i];
                                  final selected =
                                      controller.selectedId.value == p.id;
                                  final checked = controller.isBulkSelected(
                                    p.id,
                                  );
                                  return m.ListTile(
                                    selected: selected,
                                    title: Text(p.name),
                                    leading: m.Checkbox(
                                      value: checked,
                                      onChanged: (v) => controller
                                          .setBulkSelected(p.id, v == true),
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          m.CrossAxisAlignment.start,
                                      mainAxisSize: m.MainAxisSize.min,
                                      children: [
                                        Text(
                                          path.basename(p.relativePath),
                                        ).mono(),
                                        Text(
                                          p.description.isEmpty
                                              ? '—'
                                              : p.description,
                                        ).muted(),
                                      ],
                                    ),
                                    trailing: Text(
                                      formatDateTime(p.updatedAt),
                                    ).mono(),
                                    onTap: () async {
                                      if (selected) return;
                                      if (controller.dirty.value) {
                                        final ok = await confirmDiscardChanges(
                                          context,
                                          message:
                                              '当前 Playbook 有未保存修改，切换将丢失这些修改。',
                                          discardLabel: '丢弃并切换',
                                        );
                                        if (!ok) return;
                                        controller.discardEdits();
                                      }
                                      controller.selectedId.value = p.id;
                                    },
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
                    final meta = controller.selected;
                    if (meta == null) {
                      return const Card(
                        child: Center(child: Text('选择一个 Playbook 查看详情')),
                      );
                    }
                    return _PlaybookDetail(meta: meta);
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

class _PlaybookDetail extends StatefulWidget {
  final PlaybookMeta meta;

  const _PlaybookDetail({required this.meta});

  @override
  State<_PlaybookDetail> createState() => _PlaybookDetailState();
}

class _PlaybookDetailState extends State<_PlaybookDetail> {
  late final TextEditingController _editor;
  late final Worker _worker;
  bool _syncingFromController = false;

  PlaybooksController get _controller => Get.find<PlaybooksController>();

  @override
  void initState() {
    super.initState();
    _editor = TextEditingController(text: _controller.editingText.value);
    _editor.addListener(() {
      if (_syncingFromController) return;
      _controller.updateEditingText(_editor.text);
    });
    _worker = ever<String>(_controller.editingText, (text) {
      if (_editor.text == text) return;
      _syncingFromController = true;
      _editor.text = text;
      _editor.selection = TextSelection.collapsed(offset: text.length);
      _syncingFromController = false;
    });
  }

  @override
  void dispose() {
    _worker.dispose();
    _editor.dispose();
    super.dispose();
  }

  void _validateYamlOrThrow(String text) {
    if (text.length > 2 * 1024 * 1024) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '文件过大',
        message: 'YAML 内容过大，已超过 2MB，可能导致编辑器卡顿。',
        suggestion: '拆分 Playbook，或仅保留必要内容后再保存。',
      );
    }
    final lines = '\n'.allMatches(text).length + 1;
    if (lines > 50000) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '行数过多',
        message: 'YAML 行数过多（> 50000），可能导致编辑器卡顿。',
        suggestion: '拆分 Playbook，或仅保留必要内容后再保存。',
      );
    }
    try {
      loadYaml(text);
    } on YamlException catch (e) {
      final span = e.span;
      final loc = span == null
          ? ''
          : ' (line ${span.start.line + 1}, col ${span.start.column + 1})';
      throw AppException(
        code: AppErrorCode.yamlInvalid,
        title: 'YAML 语法错误',
        message: '${e.message}$loc',
        suggestion: '修复 YAML 缩进/冒号/列表等语法后重试。',
        cause: e,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final PlaybookMeta meta = widget.meta;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.r),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Obx(() {
                    final dirty = _controller.dirty.value;
                    return Row(
                      children: [
                        Text(meta.name).h2(),
                        if (dirty) ...[
                          SizedBox(width: 8.w),
                          const Text('（未保存）').muted(),
                        ],
                      ],
                    );
                  }),
                ),
                DestructiveButton(
                  onPressed: () async {
                    if (_controller.dirty.value) {
                      final ok = await confirmDiscardChanges(
                        context,
                        message: '当前 Playbook 有未保存修改，删除将丢失这些修改。',
                        discardLabel: '丢弃并删除',
                      );
                      if (!ok) return;
                      _controller.discardEdits();
                    }
                    if (!context.mounted) return;
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('删除 Playbook？'),
                        content: Text('将同时删除 YAML 文件：${meta.relativePath}'),
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
                      await _controller.deleteSelected();
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
            SizedBox(height: 8.h),
            Text('路径: ${meta.relativePath}').mono(),
            SizedBox(height: 8.h),
            Text('更新时间: ${formatDateTime(meta.updatedAt)}').mono(),
            SizedBox(height: 12.h),
            Row(
              children: [
                Expanded(child: Text('内容').p()),
                PrimaryButton(
                  onPressed: () async {
                    final text = _editor.text;
                    try {
                      _validateYamlOrThrow(text);
                      await _controller.saveSelected(text: text);
                      if (context.mounted) {
                        showToast(
                          context: context,
                          builder: (context, overlay) => Card(
                            child: Padding(
                              padding: EdgeInsets.all(12.r),
                              child: Row(
                                children: [
                                  const Expanded(child: Text('保存成功')),
                                  GhostButton(
                                    density: ButtonDensity.icon,
                                    onPressed: overlay.close,
                                    child: const Icon(Icons.close),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }
                    } on AppException catch (e) {
                      if (context.mounted) {
                        await showAppErrorDialog(context, e);
                      }
                    }
                  },
                  child: const Text('保存并校验'),
                ),
              ],
            ),
            SizedBox(height: 8.h),
            Expanded(child: TextArea(controller: _editor)),
          ],
        ),
      ),
    );
  }
}

class _CreatePlaybookResult {
  final String name;
  final String fileName;
  final String description;

  const _CreatePlaybookResult({
    required this.name,
    required this.fileName,
    required this.description,
  });
}

class _CreatePlaybookDialog extends StatefulWidget {
  const _CreatePlaybookDialog();

  @override
  State<_CreatePlaybookDialog> createState() => _CreatePlaybookDialogState();
}

class _CreatePlaybookDialogState extends State<_CreatePlaybookDialog> {
  final m.TextEditingController _name = m.TextEditingController();
  final m.TextEditingController _fileName = m.TextEditingController();
  final m.TextEditingController _desc = m.TextEditingController();
  bool _fileNameTouched = false;

  static String _suggestFileName(String name) {
    final s = name.trim().toLowerCase();
    if (s.isEmpty) return '';
    final normalized = s.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final trimmed = normalized.replaceAll(RegExp(r'^_+|_+$'), '');
    if (trimmed.isEmpty) return '';
    return '$trimmed.yml';
  }

  @override
  void dispose() {
    _name.dispose();
    _fileName.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新增 Playbook'),
      content: SizedBox(
        width: 520.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            m.TextField(
              controller: _name,
              decoration: const m.InputDecoration(labelText: '名称'),
              onChanged: (v) {
                if (_fileNameTouched) return;
                final s = _suggestFileName(v);
                if (s.isEmpty) return;
                _fileName.text = s;
              },
            ),
            SizedBox(height: 12.h),
            m.TextField(
              controller: _fileName,
              decoration: const m.InputDecoration(
                labelText: '文件名（自动补 .yml/.yaml）',
                hintText: '例如：deploy.yml',
              ),
              onChanged: (_) => _fileNameTouched = true,
            ),
            SizedBox(height: 12.h),
            m.TextField(
              controller: _desc,
              decoration: const m.InputDecoration(labelText: '描述（可选）'),
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
          onPressed: () {
            final name = _name.text.trim();
            final fileName = _fileName.text.trim();
            if (name.isEmpty) return;
            if (fileName.isEmpty) return;
            Navigator.of(context).pop(
              _CreatePlaybookResult(
                name: name,
                fileName: fileName,
                description: _desc.text.trim(),
              ),
            );
          },
          child: const Text('创建'),
        ),
      ],
    );
  }
}

class _BulkDeletePlaybooksDialog extends StatefulWidget {
  final int count;

  const _BulkDeletePlaybooksDialog({required this.count});

  @override
  State<_BulkDeletePlaybooksDialog> createState() =>
      _BulkDeletePlaybooksDialogState();
}

class _BulkDeletePlaybooksDialogState
    extends State<_BulkDeletePlaybooksDialog> {
  final m.TextEditingController _confirm = m.TextEditingController();

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('批量删除 Playbook？'),
      content: SizedBox(
        width: 520.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('将删除 ${widget.count} 个 Playbook（不可恢复）。'),
            SizedBox(height: 12.h),
            const Text('二次确认：输入 DELETE 继续').muted(),
            SizedBox(height: 8.h),
            m.TextField(
              controller: _confirm,
              decoration: const m.InputDecoration(hintText: 'DELETE'),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        DestructiveButton(
          onPressed: _confirm.text.trim() == 'DELETE'
              ? () => Navigator.of(context).pop(true)
              : null,
          child: const Text('删除'),
        ),
      ],
    );
  }
}
