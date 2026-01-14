import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:flutter/material.dart' as m;

import '../../controllers/projects_controller.dart';
import '../../controllers/playbooks_controller.dart';
import '../../../services/core/app_error.dart';
import '../../widgets/app_error_dialog.dart';
import '../../widgets/confirm_dialogs.dart';

class ProjectsPage extends StatelessWidget {
  const ProjectsPage({super.key});

  static String _fmtUpdatedAt(DateTime dt) {
    final d = dt.toLocal();
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<bool> _confirmProjectSwitchIfNeeded(BuildContext context) async {
    if (!Get.isRegistered<PlaybooksController>()) {
      return true;
    }
    final pc = Get.find<PlaybooksController>();
    if (!pc.dirty.value) return true;
    final ok = await confirmDiscardChanges(
      context,
      message: '当前 Playbook 有未保存修改，切换项目将丢失这些修改。',
      discardLabel: '丢弃并切换',
    );
    if (!ok) return false;
    pc.discardEdits();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ProjectsController>();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          SizedBox(
            width: 320,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('项目列表').p()),
                        PrimaryButton(
                          onPressed: () async {
                            final created =
                                await showDialog<_ProjectUpsertResult>(
                                  context: context,
                                  builder: (context) =>
                                      const _ProjectUpsertDialog(title: '新增项目'),
                                );
                            if (created == null) return;
                            try {
                              await controller.create(
                                name: created.name,
                                description: created.description,
                              );
                            } on AppException catch (e) {
                              if (context.mounted) {
                                await showAppErrorDialog(context, e);
                              }
                            }
                          },
                          density: ButtonDensity.icon,
                          child: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    m.TextField(
                      decoration: m.InputDecoration(
                        prefixIcon: m.Icon(Icons.search),
                        labelText: '搜索（按名称）',
                      ),
                      onChanged: (v) => controller.query.value = v,
                    ),
                    const SizedBox(height: 8),
                    Obx(() {
                      final desc = controller.sortUpdatedAtDesc.value;
                      return Row(
                        children: [
                          Expanded(child: Text('按更新时间排序').muted()),
                          GhostButton(
                            density: ButtonDensity.icon,
                            onPressed: () =>
                                controller.sortUpdatedAtDesc.value = !desc,
                            child: Icon(
                              desc ? Icons.arrow_downward : Icons.arrow_upward,
                            ),
                          ),
                        ],
                      );
                    }),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Obx(() {
                        final items = controller.visibleProjects;
                        if (items.isEmpty) {
                          return const Center(child: Text('暂无项目'));
                        }
                        return m.ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            final p = items[i];
                            final selected =
                                controller.selectedId.value == p.id;
                            return m.ListTile(
                              selected: selected,
                              title: Text(p.name),
                              subtitle: Text(
                                p.description.isEmpty ? '—' : p.description,
                              ).muted(),
                              trailing: Text(_fmtUpdatedAt(p.updatedAt)).mono(),
                              onTap: () async {
                                if (selected) return;
                                final ok = await _confirmProjectSwitchIfNeeded(
                                  context,
                                );
                                if (!ok) return;
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
          const SizedBox(width: 16),
          Expanded(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Obx(() {
                  final p = controller.selected;
                  if (p == null) {
                    return const Center(child: Text('选择一个项目查看详情'));
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(p.name).h2()),
                          GhostButton(
                            onPressed: () async {
                              final edited =
                                  await showDialog<_ProjectUpsertResult>(
                                    context: context,
                                    builder: (context) => _ProjectUpsertDialog(
                                      title: '编辑项目',
                                      initialName: p.name,
                                      initialDesc: p.description,
                                    ),
                                  );
                              if (edited == null) return;
                              try {
                                await controller.updateSelected(
                                  name: edited.name,
                                  description: edited.description,
                                );
                              } on AppException catch (e) {
                                if (context.mounted) {
                                  await showAppErrorDialog(context, e);
                                }
                              }
                            },
                            child: const Text('编辑'),
                          ),
                          const SizedBox(width: 8),
                          DestructiveButton(
                            onPressed: () async {
                              if (Get.isRegistered<PlaybooksController>()) {
                                final pc = Get.find<PlaybooksController>();
                                if (pc.dirty.value) {
                                  final ok = await confirmDiscardChanges(
                                    context,
                                    message: '当前 Playbook 有未保存修改，删除项目将丢失这些修改。',
                                    discardLabel: '丢弃并继续',
                                  );
                                  if (!ok) return;
                                  pc.discardEdits();
                                }
                              }
                              if (!context.mounted) return;
                              final ok = await confirmDeleteProject(
                                context,
                                projectName: p.name,
                              );
                              if (!ok) return;
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
                      const SizedBox(height: 12),
                      Text('ID: ${p.id}').mono(),
                      const SizedBox(height: 8),
                      Text('创建时间: ${p.createdAt.toIso8601String()}').mono(),
                      const SizedBox(height: 8),
                      Text('更新时间: ${p.updatedAt.toIso8601String()}').mono(),
                      const SizedBox(height: 16),
                      Text('说明').p(),
                      Text('v1：项目用于隔离服务器/Playbook/任务/批次等配置。').muted(),
                    ],
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectUpsertResult {
  final String name;
  final String description;

  const _ProjectUpsertResult({required this.name, required this.description});
}

class _ProjectUpsertDialog extends StatefulWidget {
  final String title;
  final String initialName;
  final String initialDesc;

  const _ProjectUpsertDialog({
    required this.title,
    this.initialName = '',
    this.initialDesc = '',
  });

  @override
  State<_ProjectUpsertDialog> createState() => _ProjectUpsertDialogState();
}

class _ProjectUpsertDialogState extends State<_ProjectUpsertDialog> {
  late final m.TextEditingController _name;
  late final m.TextEditingController _desc;

  @override
  void initState() {
    super.initState();
    _name = m.TextEditingController(text: widget.initialName);
    _desc = m.TextEditingController(text: widget.initialDesc);
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final okLabel = widget.title == '新增项目' ? '创建' : '保存';
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            m.TextField(
              controller: _name,
              decoration: const m.InputDecoration(labelText: '名称（必填）'),
            ),
            const SizedBox(height: 12),
            m.TextField(
              controller: _desc,
              decoration: const m.InputDecoration(labelText: '简介（可选）'),
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
            if (name.isEmpty) return;
            Navigator.of(context).pop(
              _ProjectUpsertResult(name: name, description: _desc.text.trim()),
            );
          },
          child: Text(okLabel),
        ),
      ],
    );
  }
}
