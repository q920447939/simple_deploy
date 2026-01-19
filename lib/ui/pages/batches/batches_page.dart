import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' as m;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../../model/batch.dart';
import '../../../model/file_slot.dart';
import '../../../model/run.dart';
import '../../../model/run_inputs.dart';
import '../../../model/server.dart';
import '../../../model/task.dart';
import '../../../services/app_services.dart';
import '../../../services/core/app_error.dart';
import '../../../services/ssh/ssh_service.dart';
import '../../controllers/batches_controller.dart';
import '../../widgets/app_error_dialog.dart';
import '../../widgets/confirm_dialogs.dart';
import '../../widgets/project_guard.dart';
import '../../utils/date_time_fmt.dart';

class BatchesPage extends StatelessWidget {
  const BatchesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.put(BatchesController());

    return ProjectGuard(
      child: Scaffold(
        child: Row(
          children: [
            _buildBatchList(context, controller),
            const VerticalDivider(),
            Expanded(
              child: Obx(() {
                final batch = controller.selectedBatch;
                if (batch == null) {
                  return const Center(child: Text('请选择一个批次'));
                }
                return _BatchDetail(batch: batch);
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatchList(BuildContext context, BatchesController controller) {
    return SizedBox(
      width: 280.w,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(12.r),
            child: Row(
              children: [
                Expanded(
                  child: Obx(
                    () => m.DropdownButton<String>(
                      isExpanded: true,
                      value: controller.filterStatus.value,
                      items: const [
                        m.DropdownMenuItem(value: 'all', child: Text('全部状态')),
                        m.DropdownMenuItem(
                          value: 'paused',
                          child: Text('Paused'),
                        ),
                        m.DropdownMenuItem(
                          value: 'running',
                          child: Text('Running'),
                        ),
                        m.DropdownMenuItem(
                          value: 'ended',
                          child: Text('Ended'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) controller.filterStatus.value = v;
                      },
                      underline: const SizedBox(),
                    ),
                  ),
                ),
                SizedBox(width: 8.w),
                PrimaryButton(
                  density: ButtonDensity.icon,
                  onPressed: () async {
                    if (controller.projectId == null) return;
                    final batch = await showDialog<Batch>(
                      context: context,
                      builder: (context) => _BatchEditDialog(
                        initial: null,
                        servers: controller.servers,
                        tasks: controller.tasks,
                      ),
                    );
                    if (batch != null) {
                      try {
                        await controller.upsertBatch(batch);
                      } on AppException catch (e) {
                        if (context.mounted) {
                          await showAppErrorDialog(context, e);
                        }
                      }
                    }
                  },
                  child: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: Obx(() {
              final list = controller.visibleBatches;
              if (list.isEmpty) {
                return const Center(child: Text('无批次'));
              }
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final b = list[index];
                  final isSelected = controller.selectedBatchId.value == b.id;
                  final statusColor = switch (b.status) {
                    BatchStatus.running => m.Colors.blue,
                    BatchStatus.ended => m.Colors.grey,
                    BatchStatus.paused => m.Colors.orange,
                    _ => m.Colors.black,
                  };

                  return GestureDetector(
                    onTap: () => controller.selectedBatchId.value = b.id,
                    child: Container(
                      color: isSelected
                          ? Theme.of(context).colorScheme.muted
                          : Colors.transparent,
                      padding: EdgeInsets.symmetric(
                        horizontal: 12.w,
                        vertical: 10.h,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 8.r,
                                height: 8.r,
                                decoration: BoxDecoration(
                                  color: statusColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              SizedBox(width: 8.w),
                              Expanded(
                                child: Text(
                                  b.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          if (b.description.isNotEmpty) ...[
                            SizedBox(height: 4.h),
                            Text(
                              b.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.sp,
                                color: Theme.of(
                                  context,
                                ).colorScheme.mutedForeground,
                              ),
                            ),
                          ],
                          SizedBox(height: 4.h),
                          Row(
                            children: [
                              Text(
                                b.status.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 10.sp,
                                  fontWeight: FontWeight.bold,
                                  color: statusColor,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                formatDateTime(b.updatedAt),
                                style: TextStyle(
                                  fontSize: 10.sp,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.mutedForeground,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _BatchDetail extends StatelessWidget {
  final Batch batch;

  const _BatchDetail({required this.batch});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BatchesController>();
    final servers = controller.servers;
    final control = servers.firstWhereOrNull(
      (s) => s.id == batch.controlServerId,
    );
    final managed = servers
        .where((s) => batch.managedServerIds.contains(s.id))
        .toList();
    final tasks = batch.taskOrder
        .map((id) => controller.taskById(id))
        .whereType<Task>()
        .toList();

    return Row(
      children: [
        SizedBox(
          width: 320.w, // Fixed sidebar width
          child: _BatchSidebar(
            batch: batch,
            control: control,
            managed: managed,
            tasks: tasks,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: _BatchLogArea(batch: batch)),
      ],
    );
  }
}

class _BatchSidebar extends StatelessWidget {
  final Batch batch;
  final Server? control;
  final List<Server> managed;
  final List<Task> tasks;

  const _BatchSidebar({
    required this.batch,
    required this.control,
    required this.managed,
    required this.tasks,
  });

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BatchesController>();

    void onEdit() async {
      final updated = await showDialog<Batch>(
        context: context,
        builder: (context) => _BatchEditDialog(
          initial: batch,
          servers: controller.servers,
          tasks: controller.tasks,
        ),
      );
      if (updated != null) {
        try {
          await controller.upsertBatch(updated);
        } on AppException catch (e) {
          if (context.mounted) {
            await showAppErrorDialog(context, e);
          }
        }
      }
    }

    Future<void> onExecute() async {
      final inputs = await showDialog<RunInputs>(
        context: context,
        builder: (context) => _BatchInputsDialog(tasks: tasks),
      );
      if (inputs == null) return;
      try {
        await controller.startRunWithInputs(inputs);
      } on AppException catch (e) {
        if (e.code == AppErrorCode.validation &&
            e.message.contains('检测到控制端环境不支持')) {
          if (!context.mounted) return;
          final allow = await _maybeConfirmUnsupportedControlAutoInstall(
            context,
            control!,
          );
          if (allow == true) {
            await controller.startRunWithInputs(
              inputs,
              allowUnsupportedControlOsAutoInstall: true,
            );
          }
        } else {
          if (context.mounted) {
            await showAppErrorDialog(context, e);
          }
        }
      }
    }

    Future<void> onExecuteReuseLast() async {
      var inputs = await controller.readLastInputs(batch.id);
      if (inputs == null) {
        if (context.mounted) {
          showDialog(
            context: context,
            builder: (context) => const AlertDialog(
              title: Text('无上次输入'),
              content: Text('未找到上次执行的输入记录，请使用“选择输入并执行”。'),
            ),
          );
        }
        return;
      }

      final check = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认沿用上次输入？'),
          content: const Text('将使用上次的文件参数和变量直接开始执行。'),
          actions: [
            OutlineButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            PrimaryButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('执行'),
            ),
          ],
        ),
      );
      if (check != true) return;

      try {
        await controller.startRunWithInputs(inputs);
      } on AppException catch (e) {
        if (e.code == AppErrorCode.validation &&
            e.message.contains('检测到控制端环境不支持')) {
          if (context.mounted) {
            final allow = await _maybeConfirmUnsupportedControlAutoInstall(
              context,
              control!,
            );
            if (allow == true) {
              await controller.startRunWithInputs(
                inputs,
                allowUnsupportedControlOsAutoInstall: true,
              );
            }
          }
        } else {
          if (context.mounted) {
            await showAppErrorDialog(context, e);
          }
        }
      }
    }

    final paused = batch.status == BatchStatus.paused;
    final running = batch.status == BatchStatus.running;
    final ended = batch.status == BatchStatus.ended;

    return Column(
      children: [
        // Header Actions
        Container(
          padding: EdgeInsets.all(12.r),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).colorScheme.border),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      batch.name,
                      style: m.Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (paused)
                    GhostButton(
                      density: ButtonDensity.icon,
                      onPressed: onEdit,
                      child: const Icon(Icons.edit, size: 16),
                    ),
                ],
              ),
              SizedBox(height: 12.h),
              if (paused) ...[
                PrimaryButton(
                  onPressed: onExecute,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.play_arrow, size: 16),
                      SizedBox(width: 8),
                      Text('运行'),
                    ],
                  ),
                ),
                SizedBox(height: 8.h),
                OutlineButton(
                  onPressed: onExecuteReuseLast,
                  child: const Text('沿用上次参数运行'),
                ),
              ] else if (running) ...[
                const PrimaryButton(
                  onPressed: null,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: m.CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(width: 8),
                      Text('执行中'),
                    ],
                  ),
                ),
              ] else if (ended) ...[
                OutlineButton(
                  onPressed: controller.resetToPaused,
                  child: const Text('重置为暂停 (Reset)'),
                ),
              ],

              if (!paused) ...[
                SizedBox(height: 12.h),
                Row(
                  children: [
                    Expanded(
                      child: DestructiveButton(
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('强制解锁？'),
                              content: const Text(
                                '警告：这将强制释放文件锁并将状态置为 Paused。\n请确保后台没有残留进程（如 Ansible），否则可能导致并发冲突。',
                              ),
                              actions: [
                                OutlineButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(false),
                                  child: const Text('取消'),
                                ),
                                DestructiveButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(true),
                                  child: const Text('确定'),
                                ),
                              ],
                            ),
                          );
                          if (ok == true) {
                            try {
                              await controller.forceUnlockAndReset();
                            } on AppException catch (e) {
                              if (context.mounted) {
                                showAppErrorDialog(context, e);
                              }
                            }
                          }
                        },
                        child: const Text('强制解锁'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),

        // Info Grid
        Expanded(
          child: ListView(
            padding: EdgeInsets.all(12.r),
            children: [
              _InfoItem(
                label: '控制端',
                value: control?.name ?? 'Unknown',
                icon: Icons.computer,
              ),
              _InfoItem(
                label: '被控端',
                value: '${managed.length} 台',
                icon: Icons.lan,
              ),
              _InfoItem(
                label: 'Task 数',
                value: '${tasks.length} 个',
                icon: Icons.task,
              ),

              const Divider(),
              Padding(
                padding: EdgeInsets.symmetric(vertical: 8.h),
                child: Text(
                  '执行记录 (Runs)',
                  style: m.Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Obx(() {
                final runs = controller.runs;
                if (runs.isEmpty) {
                  return const Text('暂无记录').muted();
                }
                return Column(
                  children: runs.map((r) {
                    final isSelected = controller.selectedRunId.value == r.id;
                    return GestureDetector(
                      onTap: () => controller.selectedRunId.value = r.id,
                      child: Container(
                        margin: EdgeInsets.only(bottom: 4.h),
                        padding: EdgeInsets.all(8.r),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Theme.of(context).colorScheme.muted
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: isSelected
                                ? Theme.of(context).colorScheme.border
                                : Colors.transparent,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _runStatusIcon(r.status),
                              size: 14,
                              color: _runStatusColor(r.status),
                            ),
                            SizedBox(width: 8.w),
                            Expanded(
                              child: Text(
                                formatDateTime(r.startedAt),
                                style: const TextStyle(fontFamily: 'GeistMono'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              }),

              const Divider(),
              Padding(
                padding: EdgeInsets.symmetric(vertical: 8.h),
                child: Text(
                  '任务进度',
                  style: m.Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Obx(() {
                final run = controller.selectedRun;
                final results = run?.taskResults ?? const <TaskRunResult>[];

                return Column(
                  children: [
                    for (var i = 0; i < tasks.length; i++)
                      _TaskStepItem(
                        task: tasks[i],
                        index: i,
                        result: results.firstWhereOrNull(
                          (r) => r.taskId == tasks[i].id,
                        ),
                        isSelected: controller.selectedTaskIndex.value == i,
                        onTap: () => controller.selectedTaskIndex.value = i,
                      ),
                  ],
                );
              }),
            ],
          ),
        ),

        if (paused)
          Padding(
            padding: EdgeInsets.all(12.r),
            child: SecondaryButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('删除批次'),
                    content: Text('确认删除批次 "${batch.name}"？此操作不可恢复。'),
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
                if (ok == true) {
                  try {
                    await controller.deleteSelectedBatch();
                  } catch (e) {
                    // ignore
                  }
                }
              },
              child: const Text('删除批次'),
            ),
          ),
      ],
    );
  }

  IconData _runStatusIcon(String status) {
    return switch (status) {
      RunStatus.running => Icons.play_circle,
      RunResult.success => Icons.check_circle,
      RunResult.failed => Icons.error,
      'cancelled' => Icons.cancel, // Manual check if applicable
      _ => Icons.help,
    };
  }

  Color _runStatusColor(String status) {
    return switch (status) {
      RunStatus.running => m.Colors.blue,
      RunResult.success => m.Colors.green,
      RunResult.failed => m.Colors.red,
      _ => m.Colors.grey,
    };
  }
}

class _InfoItem extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _InfoItem({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4.h),
      child: Row(
        children: [
          Icon(
            icon,
            size: 14,
            color: Theme.of(context).colorScheme.mutedForeground,
          ),
          SizedBox(width: 8.w),
          Text(
            '$label:',
            style: TextStyle(
              color: Theme.of(context).colorScheme.mutedForeground,
            ),
          ),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskStepItem extends StatelessWidget {
  final Task task;
  final int index;
  final TaskRunResult? result;
  final bool isSelected;
  final VoidCallback onTap;

  const _TaskStepItem({
    required this.task,
    required this.index,
    required this.result,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final status = result?.status ?? TaskExecStatus.waiting;
    final color = switch (status) {
      TaskExecStatus.running => m.Colors.blue,
      TaskExecStatus.success => m.Colors.green,
      TaskExecStatus.failed => m.Colors.red,
      _ => m.Colors.grey.shade400,
    };

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 6.h),
        padding: EdgeInsets.all(8.r),
        decoration: BoxDecoration(
          // ignore: deprecated_member_use
          color: isSelected
              ? Theme.of(context).colorScheme.muted.withOpacity(0.5)
              : Colors.transparent,
          border: Border.all(
            color: isSelected
                ? Theme.of(context).colorScheme.border
                : Colors.transparent,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected ? color : Colors.transparent,
                border: Border.all(color: color),
                shape: BoxShape.circle,
              ),
              child: isSelected
                  ? Text(
                      '${index + 1}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : Text(
                      '${index + 1}',
                      style: TextStyle(fontSize: 10, color: color),
                    ),
            ),
            SizedBox(width: 10.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.name,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  if (result?.exitCode != null)
                    Text(
                      'Exit: ${result!.exitCode}',
                      style: TextStyle(fontSize: 10.sp, color: color),
                    ),
                ],
              ),
            ),
            if (status == TaskExecStatus.running)
              const SizedBox(
                width: 12,
                height: 12,
                child: m.CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }
}

class _BatchLogArea extends StatefulWidget {
  final Batch batch;

  const _BatchLogArea({required this.batch});

  @override
  State<_BatchLogArea> createState() => _BatchLogAreaState();
}

class _BatchLogAreaState extends State<_BatchLogArea> {
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    final controller = Get.find<BatchesController>();
    // Auto scroll logic
    ever(controller.currentLogLines, (_) {
      if (_autoScroll && _scrollController.hasClients) {
        // Wait for build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
            );
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BatchesController>();

    return Column(
      children: [
        // Toolbar
        Container(
          height: 48.h,
          padding: EdgeInsets.symmetric(horizontal: 16.w),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).colorScheme.border),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.terminal, size: 16),
              SizedBox(width: 8.w),
              const Text(
                'Execution Logs',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Spacer(),

              Obx(
                () => Text(
                  '${controller.currentLogLines.length} lines',
                  style: TextStyle(fontFamily: 'GeistMono', fontSize: 12.sp),
                ).muted(),
              ),
              SizedBox(width: 16.w),

              // Toolbar Actions
              OutlineButton(
                density: ButtonDensity.icon,
                onPressed: controller.refreshLog,
                child: const Icon(Icons.refresh, size: 14),
              ),
              SizedBox(width: 8.w),
              GhostButton(
                density: ButtonDensity.icon,
                onPressed: () {
                  setState(() => _autoScroll = !_autoScroll);
                },
                child: Icon(
                  _autoScroll
                      ? Icons.arrow_downward
                      : Icons.vertical_align_center,
                  size: 14,
                  color: _autoScroll ? m.Colors.blue : null,
                ),
              ),
              SizedBox(width: 8.w),
              OutlineButton(
                onPressed: controller.loadFullLog,
                child: const Text('Load Full'),
              ),
            ],
          ),
        ),

        // Log Content
        Expanded(
          child: m.SelectionArea(
            child: Container(
              color: m.Colors.black,
              width: double.infinity,
              child: Obx(() {
                final lines = controller.currentLogLines;
                if (lines.isEmpty) {
                  return Center(
                    child: Text(
                      'No logs available',
                      style: TextStyle(color: m.Colors.white.withOpacity(0.3)),
                    ),
                  );
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: EdgeInsets.all(8.r),
                  itemCount: lines.length,
                  itemBuilder: (context, index) {
                    return Text(
                      lines[index],
                      style: TextStyle(
                        fontFamily: 'GeistMono',
                        fontSize: 13.sp,
                        // ignore: deprecated_member_use
                        color: m.Colors.white.withOpacity(0.9),
                        height: 1.4,
                      ),
                    );
                  },
                );
              }),
            ),
          ),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Existing Helper Functions and Dialogs (Preserved)
// -----------------------------------------------------------------------------

Future<bool?> _maybeConfirmUnsupportedControlAutoInstall(
  BuildContext context,
  Server control,
) async {
  if (control.controlOsHint == ControlOsHint.ubuntu24Plus ||
      control.controlOsHint == ControlOsHint.kylinV10Sp3) {
    return false;
  }

  final endpoint = SshEndpoint(
    host: control.ip,
    port: control.port,
    username: control.username,
    password: control.password,
  );

  final loading = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const AlertDialog(
      title: Text('检测控制端环境...'),
      content: SizedBox(
        width: 360,
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: m.CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('正在读取 /etc/os-release 并检查依赖...')),
          ],
        ),
      ),
    ),
  );

  try {
    final report = await AppServices.I.sshService.withConnection(endpoint, (
      conn,
    ) async {
      final os = await conn.execWithResult('cat /etc/os-release');
      final arch = await conn.execWithResult('uname -m');

      final pythonOk =
          (await conn.execWithResult(
            'bash -lc "command -v python3.12 >/dev/null 2>&1"',
          )).exitCode ==
          0;
      final ansibleOk =
          (await conn.execWithResult(
            'bash -lc "command -v ansible-playbook >/dev/null 2>&1"',
          )).exitCode ==
          0;

      final osText = os.exitCode == 0 ? os.stdout : '';
      final osMap = _parseOsRelease(osText);
      final pretty = (osMap['PRETTY_NAME'] ?? osMap['NAME'] ?? '').trim();
      final id = (osMap['ID'] ?? '').trim();
      final versionId = (osMap['VERSION_ID'] ?? '').trim();
      final version = (osMap['VERSION'] ?? '').trim();
      final a = arch.exitCode == 0 ? arch.stdout.trim() : 'unknown';

      final supported = _isSupportedControlOs(
        id: id,
        prettyName: pretty,
        versionId: versionId,
        version: version,
        arch: a,
        controlOsHint: control.controlOsHint,
      );
      final needRequired = !pythonOk || !ansibleOk;

      final missing = <String>[
        if (!pythonOk) 'python3.12',
        if (!ansibleOk) 'ansible-playbook',
      ];

      final detected =
          'PRETTY_NAME=${pretty.isEmpty ? 'unknown' : pretty}\n'
          'ID=${id.isEmpty ? '?' : id}\n'
          'VERSION_ID=${versionId.isEmpty ? '?' : versionId}\n'
          'VERSION=${version.isEmpty ? '?' : version}\n'
          'arch=$a';

      return (
        supported: supported,
        needRequired: needRequired,
        detected: detected,
        missing: missing,
      );
    });

    if (!report.needRequired) {
      return false;
    }
    if (report.supported) {
      return false;
    }

    if (!context.mounted) {
      return null;
    }
    final ok = await confirmProceedUnsupportedControlAutoInstall(
      context,
      detected: report.detected,
      missingRequired: report.missing,
    );
    return ok ? true : null;
  } finally {
    loading.catchError((_) {});
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

Map<String, String> _parseOsRelease(String text) {
  final map = <String, String>{};
  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final idx = line.indexOf('=');
    if (idx <= 0) continue;
    final k = line.substring(0, idx).trim();
    var v = line.substring(idx + 1).trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    map[k] = v;
  }
  return map;
}

bool _isSupportedControlOs({
  required String id,
  required String prettyName,
  required String versionId,
  required String version,
  required String arch,
  required String controlOsHint,
}) {
  final a = arch.trim();
  final isArchOk = a == 'x86_64' || a == 'aarch64' || a == 'arm64';
  if (!isArchOk) return false;

  if (controlOsHint == ControlOsHint.ubuntu24Plus) {
    return true;
  }
  if (controlOsHint == ControlOsHint.kylinV10Sp3) {
    return true;
  }
  if (controlOsHint == ControlOsHint.other) {
    return false;
  }

  final idLower = id.toLowerCase();
  final prettyLower = prettyName.toLowerCase();
  final versionIdLower = versionId.toLowerCase();
  final versionLower = version.toLowerCase();

  if (idLower == 'ubuntu') {
    final v = double.tryParse(versionIdLower.replaceAll('"', ''));
    return v != null && v >= 24.0;
  }

  final looksKylin =
      idLower.contains('kylin') ||
      prettyLower.contains('kylin') ||
      prettyLower.contains('麒麟');
  final looksV10 =
      versionIdLower.contains('v10') ||
      versionLower.contains('v10') ||
      prettyLower.contains('v10');
  final looksSp3 = versionLower.contains('sp3') || prettyLower.contains('sp3');
  return looksKylin && looksV10 && looksSp3;
}

class _BatchEditDialog extends StatefulWidget {
  final Batch? initial;
  final List<Server> servers;
  final List<Task> tasks;

  const _BatchEditDialog({
    required this.initial,
    required this.servers,
    required this.tasks,
  });

  @override
  State<_BatchEditDialog> createState() => _BatchEditDialogState();
}

class _BatchEditDialogState extends State<_BatchEditDialog> {
  final m.TextEditingController _name = m.TextEditingController();
  final m.TextEditingController _desc = m.TextEditingController();

  String? _controlId;
  final Set<String> _managed = <String>{};
  final List<String> _order = <String>[];

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    if (i != null) {
      _name.text = i.name;
      _desc.text = i.description;
      _controlId = i.controlServerId;
      _managed.addAll(i.managedServerIds);
      _order.addAll(i.taskOrder);
    } else {
      final firstControl = widget.servers
          .where((s) => s.type == ServerType.control && s.enabled)
          .toList();
      _controlId = firstControl.isEmpty ? null : firstControl.first.id;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.initial;
    final controls = widget.servers
        .where((s) => s.type == ServerType.control)
        .toList();
    final managed = widget.servers
        .where((s) => s.type == ServerType.managed)
        .toList();

    final canSave =
        _controlId != null && _managed.isNotEmpty && _order.isNotEmpty;

    return AlertDialog(
      title: Text(initial == null ? '新增批次' : '编辑批次'),
      content: SizedBox(
        width: 680.w,
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
              key: ValueKey(_controlId),
              initialValue: _controlId,
              decoration: const m.InputDecoration(labelText: '控制端'),
              items: controls
                  .map(
                    (s) => m.DropdownMenuItem(
                      value: s.id,
                      child: Text('${s.name} (${s.ip}:${s.port})'),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _controlId = v),
            ),
            SizedBox(height: 16.h),
            Row(
              children: [
                const Expanded(child: Text('选择被控端（至少 1 个）')),
                Text('${_managed.length} 已选').muted(),
              ],
            ),
            SizedBox(height: 8.h),
            SizedBox(
              height: 160.h,
              child: managed.isEmpty
                  ? const Center(child: Text('暂无被控端'))
                  : m.ListView(
                      children: [
                        for (final s in managed)
                          m.CheckboxListTile(
                            value: _managed.contains(s.id),
                            onChanged: (v) {
                              setState(() {
                                if (v == true) {
                                  _managed.add(s.id);
                                } else {
                                  _managed.remove(s.id);
                                }
                              });
                            },
                            title: Text(s.name),
                            subtitle: Text('${s.ip}:${s.port}').muted(),
                          ),
                      ],
                    ),
            ),
            SizedBox(height: 16.h),
            Row(
              children: [
                const Expanded(child: Text('任务顺序（至少 1 个）')),
                OutlineButton(
                  onPressed: () async {
                    final remaining = widget.tasks
                        .where((t) => !_order.contains(t.id))
                        .toList();
                    if (remaining.isEmpty) return;
                    final picked = await showDialog<String>(
                      context: context,
                      builder: (context) => _PickTaskDialog(tasks: remaining),
                    );
                    if (picked == null) return;
                    setState(() => _order.add(picked));
                  },
                  child: const Text('添加任务'),
                ),
              ],
            ),
            SizedBox(height: 8.h),
            SizedBox(
              height: 180.h,
              child: _order.isEmpty
                  ? const Center(child: Text('暂无任务'))
                  : m.ListView.builder(
                      itemCount: _order.length,
                      itemBuilder: (context, i) {
                        final id = _order[i];
                        final t = widget.tasks.firstWhereOrNull(
                          (x) => x.id == id,
                        );
                        return m.ListTile(
                          title: Text(t?.name ?? '未知任务'),
                          subtitle: Text('task_id=$id').muted(),
                          leading: Text('${i + 1}').mono(),
                          trailing: Wrap(
                            spacing: 4.w,
                            children: [
                              GhostButton(
                                density: ButtonDensity.icon,
                                onPressed: i == 0
                                    ? null
                                    : () => setState(() {
                                        final tmp = _order[i - 1];
                                        _order[i - 1] = _order[i];
                                        _order[i] = tmp;
                                      }),
                                child: const Icon(Icons.arrow_upward),
                              ),
                              GhostButton(
                                density: ButtonDensity.icon,
                                onPressed: i == _order.length - 1
                                    ? null
                                    : () => setState(() {
                                        final tmp = _order[i + 1];
                                        _order[i + 1] = _order[i];
                                        _order[i] = tmp;
                                      }),
                                child: const Icon(Icons.arrow_downward),
                              ),
                              GhostButton(
                                density: ButtonDensity.icon,
                                onPressed: () =>
                                    setState(() => _order.removeAt(i)),
                                child: const Icon(Icons.close),
                              ),
                            ],
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
          onPressed: canSave
              ? () {
                  final name = _name.text.trim();
                  if (name.isEmpty) return;
                  final now = DateTime.now();
                  Navigator.of(context).pop(
                    Batch(
                      id: initial?.id ?? AppServices.I.uuid.v4(),
                      name: name,
                      description: _desc.text.trim(),
                      status: initial?.status ?? BatchStatus.paused,
                      controlServerId: _controlId!,
                      managedServerIds: _managed.toList(),
                      taskOrder: List<String>.from(_order),
                      createdAt: initial?.createdAt ?? now,
                      updatedAt: now,
                      lastRunId: initial?.lastRunId,
                    ),
                  );
                }
              : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _PickTaskDialog extends StatelessWidget {
  final List<Task> tasks;

  const _PickTaskDialog({required this.tasks});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择任务'),
      content: SizedBox(
        width: 520.w,
        height: 420.h,
        child: ListView.builder(
          itemCount: tasks.length,
          itemBuilder: (context, i) {
            final t = tasks[i];
            return m.ListTile(
              title: Text(t.name),
              subtitle: Text(t.description).muted(),
              onTap: () => Navigator.of(context).pop(t.id),
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

class _BatchInputsDialog extends StatefulWidget {
  final List<Task> tasks;

  const _BatchInputsDialog({required this.tasks});

  @override
  State<_BatchInputsDialog> createState() => _BatchInputsDialogState();
}

class _BatchInputsDialogState extends State<_BatchInputsDialog> {
  final Map<String, Map<String, List<String>>> _fileInputs = {};
  final Map<String, Map<String, m.TextEditingController>> _varCtrls = {};

  @override
  void initState() {
    super.initState();
    for (final t in widget.tasks) {
      if (t.variables.isEmpty) continue;
      final byVar = _varCtrls.putIfAbsent(
        t.id,
        () => <String, m.TextEditingController>{},
      );
      for (final v in t.variables) {
        byVar.putIfAbsent(
          v.name,
          () => m.TextEditingController(text: v.defaultValue),
        );
      }
    }
  }

  @override
  void dispose() {
    for (final byVar in _varCtrls.values) {
      for (final c in byVar.values) {
        c.dispose();
      }
    }
    super.dispose();
  }

  List<String> _ensureList(String taskId, String slotName) {
    final byTask = _fileInputs.putIfAbsent(
      taskId,
      () => <String, List<String>>{},
    );
    return byTask.putIfAbsent(slotName, () => <String>[]);
  }

  bool get _canStart {
    for (final t in widget.tasks) {
      for (final s in t.fileSlots.where((x) => x.required)) {
        final list = _fileInputs[t.id]?[s.name] ?? const <String>[];
        if (list.isEmpty) return false;
      }
      for (final v in t.variables.where((x) => x.required)) {
        final c = _varCtrls[t.id]?[v.name];
        final text = c?.text ?? '';
        if (text.trim().isEmpty) return false;
      }
    }
    return true;
  }

  RunInputs _normalized() {
    final outFiles = <String, Map<String, List<String>>>{};
    for (final entry in _fileInputs.entries) {
      final slots = <String, List<String>>{};
      for (final s in entry.value.entries) {
        final list = s.value.where((x) => x.trim().isNotEmpty).toList();
        if (list.isEmpty) continue;
        slots[s.key] = list;
      }
      if (slots.isEmpty) continue;
      outFiles[entry.key] = slots;
    }

    final outVars = <String, Map<String, String>>{};
    for (final t in widget.tasks) {
      if (t.variables.isEmpty) continue;
      final byVar = _varCtrls[t.id];
      if (byVar == null) continue;
      outVars[t.id] = <String, String>{
        for (final v in t.variables) v.name: (byVar[v.name]?.text ?? ''),
      };
    }

    return RunInputs(fileInputs: outFiles, vars: outVars);
  }

  Future<void> _pickFiles(Task task, FileSlot slot) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: slot.multiple,
      dialogTitle: '选择文件：${task.name} / ${slot.name}',
    );
    if (result == null) return;
    final picked = result.paths.whereType<String>().toList();
    if (picked.isEmpty) return;
    setState(() {
      final list = _ensureList(task.id, slot.name);
      if (slot.multiple) {
        for (final x in picked) {
          if (!list.contains(x)) list.add(x);
        }
      } else {
        list
          ..clear()
          ..add(picked.first);
      }
    });
  }

  void _remove(Task task, FileSlot slot, String path) {
    setState(() {
      final list = _ensureList(task.id, slot.name);
      list.remove(path);
      if (list.isEmpty) {
        _fileInputs[task.id]?.remove(slot.name);
        if ((_fileInputs[task.id]?.isEmpty ?? false)) {
          _fileInputs.remove(task.id);
        }
      }
    });
  }

  void _clear(Task task, FileSlot slot) {
    setState(() {
      _fileInputs[task.id]?.remove(slot.name);
      if ((_fileInputs[task.id]?.isEmpty ?? false)) {
        _fileInputs.remove(task.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择运行输入'),
      content: SizedBox(
        width: 760.w,
        height: 560.h,
        child: m.ListView(
          children: [
            const Text('说明：必选变量/必选槽位未填写/未选择文件将无法开始执行。').muted(),
            SizedBox(height: 12.h),
            for (var ti = 0; ti < widget.tasks.length; ti++) ...[
              if (ti > 0) const Divider(),
              Text(widget.tasks[ti].name).p(),
              SizedBox(height: 6.h),
              if (widget.tasks[ti].variables.isNotEmpty) ...[
                for (final v in widget.tasks[ti].variables) ...[
                  m.TextField(
                    controller: _varCtrls[widget.tasks[ti].id]?[v.name],
                    decoration: m.InputDecoration(
                      labelText: v.required ? '${v.name}（必填）' : v.name,
                      helperText: v.description.trim().isEmpty
                          ? null
                          : v.description.trim(),
                    ),
                  ),
                  SizedBox(height: 8.h),
                ],
                SizedBox(height: 6.h),
              ],
              if (widget.tasks[ti].fileSlots.isEmpty)
                Padding(
                  padding: EdgeInsets.only(bottom: 8.h),
                  child: Text('该任务没有文件槽位。').muted(),
                ),
              for (final slot in widget.tasks[ti].fileSlots) ...[
                _SlotRow(
                  slot: slot,
                  selectedPaths:
                      _fileInputs[widget.tasks[ti].id]?[slot.name] ?? const [],
                  onPick: () => _pickFiles(widget.tasks[ti], slot),
                  onClear: () => _clear(widget.tasks[ti], slot),
                  onRemove: (path) => _remove(widget.tasks[ti], slot, path),
                ),
                SizedBox(height: 10.h),
              ],
            ],
          ],
        ),
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        PrimaryButton(
          onPressed: _canStart
              ? () => Navigator.of(context).pop(_normalized())
              : null,
          child: const Text('开始执行'),
        ),
      ],
    );
  }
}

class _SlotRow extends StatelessWidget {
  final FileSlot slot;
  final List<String> selectedPaths;
  final VoidCallback onPick;
  final VoidCallback onClear;
  final void Function(String path) onRemove;

  const _SlotRow({
    required this.slot,
    required this.selectedPaths,
    required this.onPick,
    required this.onClear,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final requiredText = slot.required ? '必选' : '可选';
    final multiText = slot.multiple ? '多文件' : '单文件';
    final hasAny = selectedPaths.isNotEmpty;

    return Column(
      crossAxisAlignment: m.CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(slot.name).mono()),
            SizedBox(width: 8.w),
            Text(requiredText).muted(),
            SizedBox(width: 8.w),
            Text(multiText).muted(),
            SizedBox(width: 12.w),
            OutlineButton(
              onPressed: onPick,
              child: Text(hasAny && slot.multiple ? '添加' : '选择'),
            ),
            SizedBox(width: 8.w),
            GhostButton(
              onPressed: hasAny ? onClear : null,
              child: const Text('清空'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (selectedPaths.isEmpty)
          Text(slot.required ? '（必选）未选择文件' : '未选择').muted()
        else
          Wrap(
            spacing: 8.w,
            runSpacing: 8.h,
            children: [
              for (final path in selectedPaths)
                m.InputChip(
                  label: Text(p.basename(path)).mono(),
                  onDeleted: () => onRemove(path),
                ),
            ],
          ),
      ],
    );
  }
}
