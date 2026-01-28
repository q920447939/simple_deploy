import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' as m;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../../constants/runtime.dart';
import '../../../model/batch.dart';
import '../../../model/file_binding.dart';
import '../../../model/file_slot.dart';
import '../../../model/run.dart';
import '../../../model/run_inputs.dart';
import '../../../model/server.dart';
import '../../../model/task.dart';
import '../../../model/upload_progress.dart';
import '../../../services/app_services.dart';
import '../../../services/core/app_error.dart';
import '../../../services/ssh/ssh_service.dart';
import '../../controllers/batches_controller.dart';
import '../../widgets/app_error_dialog.dart';
import '../../widgets/confirm_dialogs.dart';
import '../../widgets/project_guard.dart';
import '../../utils/date_time_fmt.dart';

class _BatchTaskEntry {
  final BatchTaskItem item;
  final Task task;
  final int index;

  const _BatchTaskEntry({
    required this.item,
    required this.task,
    required this.index,
  });

  String get displayName =>
      item.name.trim().isEmpty ? task.name : item.name.trim();
}

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
    final taskById = {for (final t in controller.tasks) t.id: t};
    final entries = <_BatchTaskEntry>[];
    var index = 0;
    for (final item in batch.orderedTaskItems()) {
      final task = taskById[item.taskId];
      if (task == null) continue;
      entries.add(_BatchTaskEntry(item: item, task: task, index: index));
      index++;
    }

    return Column(
      children: [
        _BatchHeader(
          batch: batch,
          control: control,
          managed: managed,
          entries: entries,
        ),
        Expanded(
          child: _BatchMainArea(
            batch: batch,
            control: control,
            managed: managed,
            entries: entries,
          ),
        ),
      ],
    );
  }
}

class _BatchHeader extends StatelessWidget {
  final Batch batch;
  final Server? control;
  final List<Server> managed;
  final List<_BatchTaskEntry> entries;

  const _BatchHeader({
    required this.batch,
    required this.control,
    required this.managed,
    required this.entries,
  });

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BatchesController>();
    final running = batch.status == BatchStatus.running;
    final ended = batch.status == BatchStatus.ended;

    Color statusColor() {
      return switch (batch.status) {
        BatchStatus.running => m.Colors.blue,
        BatchStatus.ended => m.Colors.grey,
        BatchStatus.paused => m.Colors.orange,
        _ => m.Colors.grey,
      };
    }

    String statusText() {
      return switch (batch.status) {
        BatchStatus.running => '运行中',
        BatchStatus.ended => '已结束',
        BatchStatus.paused => '暂停',
        _ => batch.status,
      };
    }

    Future<void> onEditBatch() async {
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

    Future<void> onEditParams() async {
      final inputs = await showDialog<RunInputs>(
        context: context,
        builder: (context) => _BatchInputsDialog(
          entries: entries,
          actionLabel: '保存参数',
          enforceRequired: false,
        ),
      );
      if (inputs == null) return;
      try {
        await controller.updateBatchTaskInputs(batch, inputs);
      } on AppException catch (e) {
        if (context.mounted) {
          await showAppErrorDialog(context, e);
        }
      }
    }

    Future<void> onExecute() async {
      final inputs = await showDialog<RunInputs>(
        context: context,
        builder: (context) => _BatchInputsDialog(entries: entries),
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
              content: Text('未找到上次执行的输入记录，请使用“运行”选择参数。'),
            ),
          );
        }
        return;
      }

      if (!context.mounted) return;
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
      if (!context.mounted) return;
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

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).colorScheme.border),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        batch.name,
                        style: m.Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10.w,
                        vertical: 4.h,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor().withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: statusColor()),
                      ),
                      child: Text(
                        statusText(),
                        style: TextStyle(
                          fontSize: 12.sp,
                          color: statusColor(),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (batch.description.trim().isNotEmpty) ...[
                  SizedBox(height: 6.h),
                  Text(batch.description).muted(),
                ],
              ],
            ),
          ),
          SizedBox(width: 12.w),
          Wrap(
            spacing: 8.w,
            runSpacing: 8.h,
            alignment: WrapAlignment.end,
            children: [
              if (running)
                const PrimaryButton(
                  onPressed: null,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
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
                )
              else
                PrimaryButton(
                  onPressed: onExecute,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.play_arrow, size: 16),
                      SizedBox(width: 8),
                      Text('运行'),
                    ],
                  ),
                ),
              OutlineButton(
                onPressed: running ? null : onExecuteReuseLast,
                child: const Text('沿用上次参数运行'),
              ),
              OutlineButton(
                onPressed: running ? null : onEditBatch,
                child: const Text('编辑批次'),
              ),
              OutlineButton(
                onPressed: running ? null : onEditParams,
                child: const Text('编辑参数'),
              ),
              if (ended)
                OutlineButton(
                  onPressed: controller.resetToPaused,
                  child: const Text('重置为暂停'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HorizontalTaskProgressBar extends StatelessWidget {
  final List<_BatchTaskEntry> entries;

  const _HorizontalTaskProgressBar({required this.entries});

  bool _recapFailedForTask(Run? run, int taskIndex) {
    final summary = run?.ansibleSummary;
    if (summary == null) return false;
    final raw = summary['task_$taskIndex'];
    if (raw is! Map) return false;
    final failed = raw['failed'];
    final unreachable = raw['unreachable'];
    final failedCount = failed is num ? failed.toInt() : 0;
    final unreachableCount = unreachable is num ? unreachable.toInt() : 0;
    return failedCount > 0 || unreachableCount > 0;
  }

  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    final text = size < 10 && unit > 0
        ? size.toStringAsFixed(1)
        : size.toStringAsFixed(0);
    return '$text ${units[unit]}';
  }

  Widget _buildSystemStageItem(
    BuildContext context, {
    required Run? run,
    required UploadProgress? upload,
    required bool isSelected,
  }) {
    final status = run?.systemStatus ?? TaskExecStatus.waiting;
    final color = switch (status) {
      TaskExecStatus.running => m.Colors.blue,
      TaskExecStatus.success => m.Colors.green,
      TaskExecStatus.failed => m.Colors.red,
      TaskExecStatus.blocked => m.Colors.grey.shade500,
      _ => m.Colors.grey.shade400,
    };
    final statusText = switch (status) {
      TaskExecStatus.running => '准备中',
      TaskExecStatus.success => '完成',
      TaskExecStatus.failed => '失败',
      TaskExecStatus.blocked => '阻断',
      _ => '未开始',
    };
    String detail = statusText;
    if (upload != null) {
      final percent = upload.total > 0
          ? (upload.sent / upload.total * 100).clamp(0, 100)
          : 0.0;
      detail = upload.total > 0
          ? '${percent.toStringAsFixed(0)}% · ${_formatBytes(upload.sent)}/${_formatBytes(upload.total)}'
          : _formatBytes(upload.sent);
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r),
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
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 16,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isSelected ? color : Colors.transparent,
              border: Border.all(color: color, width: 1.5),
            ),
            child: Text(
              'S',
              style: TextStyle(
                fontSize: 9.sp,
                color: isSelected ? Colors.white : color,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SizedBox(width: 8.w),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '系统准备',
                style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w500),
              ),
              Text(
                detail,
                style: TextStyle(fontSize: 10.sp, color: color),
              ),
            ],
          ),
          if (status == TaskExecStatus.running) ...[
            SizedBox(width: 8.w),
            const SizedBox(
              width: 10,
              height: 10,
              child: m.CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BatchesController>();

    return Container(
      height: 64.h,
      padding: EdgeInsets.symmetric(horizontal: 16.w),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.background,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).colorScheme.border),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Obx(() {
              final run = controller.selectedRun;
              final results = run?.taskResults ?? const <TaskRunResult>[];
              final upload = controller.uploadProgress.value;

              if (entries.isEmpty) {
                return const Center(child: Text('暂无任务'));
              }

              return ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(vertical: 12.h),
                itemCount: entries.length + 1,
                separatorBuilder: (context, index) {
                  return Container(
                    width: 24.w,
                    alignment: Alignment.center,
                    child: Container(
                      height: 1,
                      color: Theme.of(context).colorScheme.border,
                    ),
                  );
                },
                itemBuilder: (context, index) {
                  if (index == 0) {
                    final isSelected =
                        controller.selectedTaskIndex.value ==
                        BatchesController.systemStageIndex;
                    return GestureDetector(
                      onTap: controller.userSelectSystemStage,
                      child: _buildSystemStageItem(
                        context,
                        run: run,
                        upload: upload,
                        isSelected: isSelected,
                      ),
                    );
                  }

                  final taskIndex = index - 1;
                  final entry = entries[taskIndex];
                  final result = taskIndex < results.length
                      ? results[taskIndex]
                      : null;
                  final isSelected =
                      controller.selectedTaskIndex.value == taskIndex;

                  // Status Logic
                  var status = result?.status ?? TaskExecStatus.waiting;
                  if (_recapFailedForTask(run, taskIndex)) {
                    status = TaskExecStatus.failed;
                  }
                  final color = switch (status) {
                    TaskExecStatus.running => m.Colors.blue,
                    TaskExecStatus.success => m.Colors.green,
                    TaskExecStatus.failed => m.Colors.red,
                    TaskExecStatus.blocked => m.Colors.grey.shade500,
                    _ => m.Colors.grey.shade400,
                  };

                  return GestureDetector(
                    onTap: () => controller.userSelectTask(taskIndex),
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 8.r),
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
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 16,
                            height: 16,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isSelected ? color : Colors.transparent,
                              border: Border.all(color: color, width: 1.5),
                            ),
                            child: isSelected
                                ? Text(
                                    '${taskIndex + 1}',
                                    style: TextStyle(
                                      fontSize: 9.sp,
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  )
                                : Text(
                                    '${taskIndex + 1}',
                                    style: TextStyle(
                                      fontSize: 9.sp,
                                      color: color,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                          ),
                          SizedBox(width: 8.w),
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.displayName,
                                style: TextStyle(
                                  fontSize: 12.sp,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (run == null)
                                Text(
                                  '未执行',
                                  style: TextStyle(
                                    fontSize: 10.sp,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.mutedForeground,
                                  ),
                                )
                              else if (result?.exitCode != null)
                                Text(
                                  'Exit: ${result!.exitCode}',
                                  style: TextStyle(
                                    fontSize: 10.sp,
                                    color: color,
                                  ),
                                ),
                            ],
                          ),
                          if (status == TaskExecStatus.running) ...[
                            SizedBox(width: 8.w),
                            const SizedBox(
                              width: 10,
                              height: 10,
                              child: m.CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            ),
                          ],
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

class _BatchMainArea extends StatefulWidget {
  final Batch batch;
  final Server? control;
  final List<Server> managed;
  final List<_BatchTaskEntry> entries;

  const _BatchMainArea({
    required this.batch,
    required this.control,
    required this.managed,
    required this.entries,
  });

  @override
  State<_BatchMainArea> createState() => _BatchMainAreaState();
}

class _BatchMainAreaState extends State<_BatchMainArea> {
  int _tabIndex = 0; // 0: 概览, 1: 任务, 2: 参数, 3: 运行记录, 4: 设置
  String _lastStatus = '';
  String? _lastRunId;
  bool _autoSwitchArmed = true;

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BatchesController>();
    return Obx(() {
      final selectedRun = controller.selectedRun;
      final running = widget.batch.status == BatchStatus.running;
      final status = widget.batch.status;
      if (_lastStatus != status) {
        _lastStatus = status;
        _autoSwitchArmed = status == BatchStatus.running;
      }
      final runId = selectedRun?.id;
      if (_lastRunId != runId) {
        _lastRunId = runId;
        _autoSwitchArmed = true;
      }

      final shouldFocusRuns = running || selectedRun != null;
      if (_autoSwitchArmed && shouldFocusRuns && _tabIndex != 3) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _tabIndex = 3);
        });
        _autoSwitchArmed = false;
      }

      return Column(
        children: [
          SizedBox(
            height: 44.h,
            child: Row(
              children: [
                _TabBtn(
                  label: '概览',
                  icon: Icons.dashboard,
                  isSelected: _tabIndex == 0,
                  onTap: () => setState(() => _tabIndex = 0),
                ),
                _TabBtn(
                  label: '任务',
                  icon: Icons.playlist_play,
                  isSelected: _tabIndex == 1,
                  onTap: () => setState(() => _tabIndex = 1),
                ),
                _TabBtn(
                  label: '参数',
                  icon: Icons.tune,
                  isSelected: _tabIndex == 2,
                  onTap: () => setState(() => _tabIndex = 2),
                ),
                _TabBtn(
                  label: '运行记录',
                  icon: Icons.article,
                  isSelected: _tabIndex == 3,
                  onTap: () => setState(() => _tabIndex = 3),
                ),
                _TabBtn(
                  label: '设置',
                  icon: Icons.settings,
                  isSelected: _tabIndex == 4,
                  onTap: () => setState(() => _tabIndex = 4),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: switch (_tabIndex) {
              0 => _BatchOverviewView(
                batch: widget.batch,
                control: widget.control,
                managed: widget.managed,
                entries: widget.entries,
              ),
              1 => _BatchTasksView(entries: widget.entries),
              2 => _BatchParametersView(
                batch: widget.batch,
                entries: widget.entries,
                control: widget.control,
              ),
              3 => _BatchRunsView(batch: widget.batch, entries: widget.entries),
              _ => _BatchSettingsView(batch: widget.batch),
            },
          ),
        ],
      );
    });
  }
}

class _BatchOverviewView extends StatelessWidget {
  final Batch batch;
  final Server? control;
  final List<Server> managed;
  final List<_BatchTaskEntry> entries;

  const _BatchOverviewView({
    required this.batch,
    required this.control,
    required this.managed,
    required this.entries,
  });

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BatchesController>();
    final lastRun = controller.lastRunByBatchId[batch.id];
    final statusText = switch (batch.status) {
      BatchStatus.running => '运行中',
      BatchStatus.ended => '已结束',
      BatchStatus.paused => '暂停',
      _ => batch.status,
    };
    final lastRunText = lastRun == null
        ? '暂无'
        : '#${lastRun.seq} · ${formatDateTime(lastRun.startedAt)}';
    final resultText = lastRun == null
        ? '未执行'
        : lastRun.result == RunResult.success
        ? '成功'
        : '失败';
    final resultColor = lastRun == null
        ? Theme.of(context).colorScheme.mutedForeground
        : lastRun.result == RunResult.success
        ? m.Colors.green
        : m.Colors.red;

    return ListView(
      padding: EdgeInsets.all(16.r),
      children: [
        Wrap(
          spacing: 12.w,
          runSpacing: 12.h,
          children: [
            _SummaryCard(label: '状态', value: statusText),
            _SummaryCard(label: '控制端', value: control?.name ?? 'Unknown'),
            _SummaryCard(label: '被控端', value: '${managed.length} 台'),
            _SummaryCard(label: '任务数', value: '${entries.length} 个'),
            _SummaryCard(label: '最近运行', value: lastRunText),
            _SummaryCard(
              label: '最近结果',
              value: resultText,
              valueColor: resultColor,
            ),
          ],
        ),
        if (batch.description.trim().isNotEmpty) ...[
          SizedBox(height: 16.h),
          Card(
            child: Padding(
              padding: EdgeInsets.all(12.r),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('说明').p(),
                  SizedBox(height: 6.h),
                  Text(batch.description).muted(),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _SummaryCard({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220.w,
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(12.r),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label).muted(),
              SizedBox(height: 6.h),
              Text(
                value,
                style: TextStyle(
                  fontSize: 16.sp,
                  fontWeight: FontWeight.w600,
                  color: valueColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BatchTasksView extends StatelessWidget {
  final List<_BatchTaskEntry> entries;

  const _BatchTasksView({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(child: Text('暂无任务'));
    }
    return ListView.separated(
      padding: EdgeInsets.all(16.r),
      itemCount: entries.length,
      separatorBuilder: (context, index) => SizedBox(height: 8.h),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final task = entry.task;
        final tags = <String>[
          task.isAnsiblePlaybook ? 'Playbook' : '脚本',
          '文件槽位 ${task.fileSlots.length}',
          '变量 ${task.variables.length}',
          if (!entry.item.enabled) '禁用',
        ];
        return Card(
          child: Padding(
            padding: EdgeInsets.all(12.r),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('${index + 1}.').muted(),
                    SizedBox(width: 8.w),
                    Expanded(
                      child: Text(
                        entry.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                if (task.description.trim().isNotEmpty) ...[
                  SizedBox(height: 6.h),
                  Text(task.description).muted(),
                ],
                SizedBox(height: 8.h),
                Wrap(
                  spacing: 8.w,
                  runSpacing: 8.h,
                  children: [for (final t in tags) _Tag(text: t)],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;

  const _Tag({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.muted,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Theme.of(context).colorScheme.border),
      ),
      child: Text(text, style: TextStyle(fontSize: 12.sp)),
    );
  }
}

class _BatchParametersView extends StatelessWidget {
  final Batch batch;
  final List<_BatchTaskEntry> entries;
  final Server? control;

  const _BatchParametersView({
    required this.batch,
    required this.entries,
    required this.control,
  });

  String _formatFileInputs(BatchTaskInputs inputs) {
    if (inputs.fileInputs.isEmpty) return '文件：未设置';
    final parts = <String>[];
    for (final e in inputs.fileInputs.entries) {
      parts.add('${e.key}(${e.value.length})');
      if (parts.length >= 3) break;
    }
    return '文件：${parts.join(', ')}';
  }

  String _formatVars(BatchTaskInputs inputs) {
    if (inputs.vars.isEmpty) return '变量：未设置';
    final parts = <String>[];
    for (final e in inputs.vars.entries) {
      if (e.key == 'python') continue;
      if (e.value.trim().isEmpty) continue;
      parts.add('${e.key}=${e.value}');
      if (parts.length >= 3) break;
    }
    if (parts.isEmpty) return '变量：未设置';
    return '变量：${parts.join(', ')}';
  }

  String _formatRunFiles(TaskRunResult? result) {
    final inputs = result?.fileInputs;
    if (inputs == null || inputs.isEmpty) return '文件：未记录';
    final parts = <String>[];
    for (final e in inputs.entries) {
      parts.add('${e.key}(${e.value.length})');
      if (parts.length >= 3) break;
    }
    return '文件：${parts.join(', ')}';
  }

  String _formatRunVars(TaskRunResult? result) {
    final vars = result?.vars;
    if (vars == null || vars.isEmpty) return '变量：未记录';
    final parts = <String>[];
    for (final e in vars.entries) {
      if (e.key == 'python') continue;
      if (e.value.trim().isEmpty) continue;
      parts.add('${e.key}=${e.value}');
      if (parts.length >= 3) break;
    }
    if (parts.isEmpty) return '变量：未记录';
    return '变量：${parts.join(', ')}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BatchesController>();
    final running = batch.status == BatchStatus.running;
    final run = controller.selectedRun;
    final showingRun = run != null;
    final canEdit = !running && !showingRun;

    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).colorScheme.border),
            ),
          ),
          child: Row(
            children: [
              Text(showingRun ? '任务参数（运行快照 #${run.seq}）' : '任务参数（批次配置）').p(),
              const Spacer(),
              if (showingRun)
                GhostButton(
                  onPressed: () {
                    controller.userPinnedRun.value = false;
                    controller.selectedRunId.value = null;
                  },
                  child: const Text('查看批次配置'),
                ),
              if (canEdit)
                OutlineButton(
                  onPressed: () async {
                    final inputs = await showDialog<RunInputs>(
                      context: context,
                      builder: (context) => _BatchInputsDialog(
                        entries: entries,
                        actionLabel: '保存参数',
                        enforceRequired: false,
                      ),
                    );
                    if (inputs == null) return;
                    try {
                      await controller.updateBatchTaskInputs(batch, inputs);
                    } on AppException catch (e) {
                      if (context.mounted) {
                        await showAppErrorDialog(context, e);
                      }
                    }
                  },
                  child: const Text('编辑参数'),
                ),
              SizedBox(width: 8.w),
              GhostButton(
                onPressed: () async {
                  if (!context.mounted) return;
                  await showDialog<void>(
                    context: context,
                    builder: (context) => _BatchSnapshotsDialog(
                      batch: batch,
                      entries: entries,
                      control: control,
                    ),
                  );
                },
                child: const Text('参数快照'),
              ),
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? const Center(child: Text('暂无任务'))
              : ListView.separated(
                  padding: EdgeInsets.all(12.r),
                  itemCount: entries.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final entry = entries[i];
                    final inputs = entry.item.inputs;
                    final result = (run != null && i < run.taskResults.length)
                        ? run.taskResults[i]
                        : null;
                    return m.ListTile(
                      title: Text(entry.displayName),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            showingRun
                                ? _formatRunFiles(result)
                                : _formatFileInputs(inputs),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ).muted(),
                          Text(
                            showingRun
                                ? _formatRunVars(result)
                                : _formatVars(inputs),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ).muted(),
                        ],
                      ),
                      trailing: canEdit
                          ? GhostButton(
                              density: ButtonDensity.icon,
                              onPressed: () async {
                                final inputs = await showDialog<RunInputs>(
                                  context: context,
                                  builder: (context) => _BatchInputsDialog(
                                    entries: [entry],
                                    actionLabel: '保存参数',
                                    enforceRequired: false,
                                  ),
                                );
                                if (inputs == null) return;
                                try {
                                  await controller.updateBatchTaskInputs(
                                    batch,
                                    inputs,
                                  );
                                } on AppException catch (e) {
                                  if (context.mounted) {
                                    await showAppErrorDialog(context, e);
                                  }
                                }
                              },
                              child: const Icon(Icons.edit, size: 16),
                            )
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _BatchRunsView extends StatelessWidget {
  final Batch batch;
  final List<_BatchTaskEntry> entries;

  const _BatchRunsView({required this.batch, required this.entries});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BatchesController>();
    return Row(
      children: [
        SizedBox(
          width: 320.w,
          child: _RunHistoryView(controller: controller),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: [
              _HorizontalTaskProgressBar(entries: entries),
              Expanded(child: _BatchLogArea(batch: batch)),
            ],
          ),
        ),
      ],
    );
  }
}

class _BatchSettingsView extends StatelessWidget {
  final Batch batch;

  const _BatchSettingsView({required this.batch});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BatchesController>();
    final running = batch.status == BatchStatus.running;
    final ended = batch.status == BatchStatus.ended;

    return ListView(
      padding: EdgeInsets.all(16.r),
      children: [
        Text('运行控制', style: m.Theme.of(context).textTheme.titleMedium),
        SizedBox(height: 8.h),
        Card(
          child: Padding(
            padding: EdgeInsets.all(12.r),
            child: Wrap(
              spacing: 8.w,
              runSpacing: 8.h,
              children: [
                OutlineButton(
                  onPressed: ended ? controller.resetToPaused : null,
                  child: const Text('重置为暂停'),
                ),
                DestructiveButton(
                  onPressed: running
                      ? () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('强制解锁？'),
                              content: const Text(
                                '警告：这将强制释放文件锁并将状态置为暂停。\\n请确保后台没有残留进程（如 Ansible），否则可能导致并发冲突。',
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
                        }
                      : null,
                  child: const Text('强制解锁'),
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: 16.h),
        Text('危险操作', style: m.Theme.of(context).textTheme.titleMedium),
        SizedBox(height: 8.h),
        Card(
          child: Padding(
            padding: EdgeInsets.all(12.r),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    running ? '运行中不可删除批次。' : '删除后不可恢复，请谨慎操作。',
                  ).muted(),
                ),
                DestructiveButton(
                  onPressed: running
                      ? null
                      : () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('删除批次'),
                              content: Text('确认删除批次 "${batch.name}"？此操作不可恢复。'),
                              actions: [
                                OutlineButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(false),
                                  child: const Text('取消'),
                                ),
                                DestructiveButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(true),
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
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TabBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _TabBtn({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          color: Colors.transparent,
          alignment: Alignment.center,
          child: Container(
            padding: EdgeInsets.symmetric(vertical: 8.h),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isSelected
                      // ignore: deprecated_member_use
                      ? m.Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 14,
                  // ignore: deprecated_member_use
                  color: isSelected
                      ? m.Theme.of(context).colorScheme.primary
                      : m.Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                SizedBox(width: 8.w),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.sp,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                    // ignore: deprecated_member_use
                    color: isSelected
                        ? m.Theme.of(context).colorScheme.primary
                        : m.Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RunHistoryView extends StatelessWidget {
  final BatchesController controller;

  const _RunHistoryView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final runs = controller.runs;
      final selectedCount = controller.bulkSelectedRunIds.length;
      if (runs.isEmpty) {
        return const Center(child: Text('暂无执行记录'));
      }
      return Column(
        children: [
          Container(
            height: 40.h,
            padding: EdgeInsets.symmetric(horizontal: 12.w),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Theme.of(context).colorScheme.border),
              ),
            ),
            child: Row(
              children: [
                Text('已选 $selectedCount').muted(),
                const Spacer(),
                GhostButton(
                  density: ButtonDensity.icon,
                  onPressed: runs.isEmpty
                      ? null
                      : controller.selectAllRunsForBulk,
                  child: const Icon(Icons.select_all, size: 16),
                ),
                SizedBox(width: 4.w),
                GhostButton(
                  density: ButtonDensity.icon,
                  onPressed: selectedCount == 0
                      ? null
                      : controller.clearRunBulkSelection,
                  child: const Icon(Icons.clear_all, size: 16),
                ),
                SizedBox(width: 4.w),
                GhostButton(
                  density: ButtonDensity.icon,
                  onPressed: selectedCount == 0
                      ? null
                      : () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (context) =>
                                _BulkDeleteRunsDialog(count: selectedCount),
                          );
                          if (ok != true) return;
                          try {
                            final ids = controller.bulkSelectedRunIds.toList(
                              growable: false,
                            );
                            await controller.deleteRuns(ids);
                          } on AppException catch (e) {
                            if (context.mounted) {
                              await showAppErrorDialog(context, e);
                            }
                          }
                        },
                  child: Icon(
                    Icons.delete_outline,
                    size: 16,
                    color: selectedCount == 0 ? null : m.Colors.red,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.all(12.r),
              itemCount: runs.length,
              itemBuilder: (context, index) {
                final r = runs[index];
                final isSelected = controller.selectedRunId.value == r.id;
                final checked = controller.isRunBulkSelected(r.id);
                return Container(
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
                      m.Checkbox(
                        value: checked,
                        onChanged: (v) =>
                            controller.setRunBulkSelected(r.id, v == true),
                        materialTapTargetSize:
                            m.MaterialTapTargetSize.shrinkWrap,
                      ),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => controller.userSelectRun(r.id),
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
                                  '#${r.seq} · ${formatDateTime(r.startedAt)}',
                                  style: const TextStyle(
                                    fontFamily: 'GeistMono',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      );
    });
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
              Obx(() {
                final isSystem =
                    controller.selectedTaskIndex.value ==
                    BatchesController.systemStageIndex;
                return Text(
                  isSystem ? '系统准备日志' : '任务日志',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                );
              }),
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
                      style: TextStyle(
                        color: m.Colors.white.withValues(alpha: 0.3),
                      ),
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
                        color: m.Colors.white.withValues(alpha: 0.9),
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

class _BulkDeleteRunsDialog extends StatefulWidget {
  final int count;

  const _BulkDeleteRunsDialog({required this.count});

  @override
  State<_BulkDeleteRunsDialog> createState() => _BulkDeleteRunsDialogState();
}

class _BulkDeleteRunsDialogState extends State<_BulkDeleteRunsDialog> {
  final m.TextEditingController _confirm = m.TextEditingController();

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('批量删除历史记录？'),
      content: SizedBox(
        width: 520.w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('将删除 ${widget.count} 条历史记录及其日志（不可恢复）。'),
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
            'bash -lc "test -x /usr/local/bin/python3.12"',
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
        if (!pythonOk) kRemotePythonPath,
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
  final looksSp3 =
      versionLower.contains('sp3') ||
      prettyLower.contains('sp3') ||
      versionLower.contains('lance') ||
      prettyLower.contains('lance');
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
  final List<BatchTaskItem> _items = <BatchTaskItem>[];

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    if (i != null) {
      _name.text = i.name;
      _desc.text = i.description;
      _controlId = i.controlServerId;
      _managed.addAll(i.managedServerIds);
      _items.addAll(i.orderedTaskItems());
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
        _controlId != null && _managed.isNotEmpty && _items.isNotEmpty;

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
            SizedBox(height: 12.h),
            m.InputDecorator(
              decoration: const m.InputDecoration(
                labelText: '远程 Python 路径（批次级，固定）',
              ),
              child: Text(kRemotePythonPath),
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
                    final existing = _items.map((i) => i.taskId).toSet();
                    final remaining = widget.tasks
                        .where((t) => !existing.contains(t.id))
                        .toList();
                    if (remaining.isEmpty) return;
                    final picked = await showDialog<List<String>>(
                      context: context,
                      builder: (context) => _PickTaskDialog(tasks: remaining),
                    );
                    if (picked == null || picked.isEmpty) return;
                    setState(() {
                      for (final id in picked) {
                        _items.add(
                          BatchTaskItem(
                            id: AppServices.I.uuid.v4(),
                            taskId: id,
                            name: '',
                            enabled: true,
                            inputs: const BatchTaskInputs.empty(),
                          ),
                        );
                      }
                    });
                  },
                  child: const Text('添加任务'),
                ),
              ],
            ),
            SizedBox(height: 8.h),
            SizedBox(
              height: 180.h,
              child: _items.isEmpty
                  ? const Center(child: Text('暂无任务'))
                  : m.ListView.builder(
                      itemCount: _items.length,
                      itemBuilder: (context, i) {
                        final item = _items[i];
                        final t = widget.tasks.firstWhereOrNull(
                          (x) => x.id == item.taskId,
                        );
                        return m.ListTile(
                          title: Text(
                            item.name.isNotEmpty
                                ? item.name
                                : (t?.name ?? '未知任务'),
                          ),
                          subtitle: Text('task_id=${item.taskId}').muted(),
                          leading: Text('${i + 1}').mono(),
                          trailing: Wrap(
                            spacing: 4.w,
                            children: [
                              GhostButton(
                                density: ButtonDensity.icon,
                                onPressed: i == 0
                                    ? null
                                    : () => setState(() {
                                        final tmp = _items[i - 1];
                                        _items[i - 1] = _items[i];
                                        _items[i] = tmp;
                                      }),
                                child: const Icon(Icons.arrow_upward),
                              ),
                              GhostButton(
                                density: ButtonDensity.icon,
                                onPressed: i == _items.length - 1
                                    ? null
                                    : () => setState(() {
                                        final tmp = _items[i + 1];
                                        _items[i + 1] = _items[i];
                                        _items[i] = tmp;
                                      }),
                                child: const Icon(Icons.arrow_downward),
                              ),
                              GhostButton(
                                density: ButtonDensity.icon,
                                onPressed: () =>
                                    setState(() => _items.removeAt(i)),
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
                      taskOrder: _items.map((i) => i.id).toList(),
                      taskItems: List<BatchTaskItem>.from(_items),
                      createdAt: initial?.createdAt ?? now,
                      updatedAt: now,
                      lastRunId: initial?.lastRunId,
                      pythonPath: kRemotePythonPath,
                      runSeq: initial?.runSeq ?? 0,
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

class _PickTaskDialog extends StatefulWidget {
  final List<Task> tasks;

  const _PickTaskDialog({required this.tasks});

  @override
  State<_PickTaskDialog> createState() => _PickTaskDialogState();
}

class _PickTaskDialogState extends State<_PickTaskDialog> {
  final Set<String> _selected = <String>{};

  List<String> _selectedInOrder() {
    final ordered = <String>[];
    for (final t in widget.tasks) {
      if (_selected.contains(t.id)) {
        ordered.add(t.id);
      }
    }
    return ordered;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择任务（可多选）'),
      content: SizedBox(
        width: 520.w,
        height: 420.h,
        child: ListView.builder(
          itemCount: widget.tasks.length,
          itemBuilder: (context, i) {
            final t = widget.tasks[i];
            final checked = _selected.contains(t.id);
            return m.CheckboxListTile(
              value: checked,
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selected.add(t.id);
                  } else {
                    _selected.remove(t.id);
                  }
                });
              },
              title: Text(t.name),
              subtitle: Text(t.description).muted(),
            );
          },
        ),
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        PrimaryButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selectedInOrder()),
          child: Text('确认（已选 ${_selected.length}）'),
        ),
      ],
    );
  }
}

class _BatchInputsDialog extends StatefulWidget {
  final List<_BatchTaskEntry> entries;
  final String actionLabel;
  final bool enforceRequired;
  final RunInputs? initialInputs;

  const _BatchInputsDialog({
    required this.entries,
    this.actionLabel = '开始执行',
    this.enforceRequired = true,
    this.initialInputs,
  });

  @override
  State<_BatchInputsDialog> createState() => _BatchInputsDialogState();
}

class _BatchInputsDialogState extends State<_BatchInputsDialog> {
  final Map<String, Map<String, List<FileBinding>>> _fileInputs = {};
  final Map<String, Map<String, m.TextEditingController>> _varCtrls = {};
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    for (final entry in widget.entries) {
      final t = entry.task;
      final initialVars =
          widget.initialInputs?.vars[entry.item.id] ??
          widget.initialInputs?.vars[entry.task.id];
      final initialFiles =
          widget.initialInputs?.fileInputs[entry.item.id] ??
          widget.initialInputs?.fileInputs[entry.task.id];
      if (t.variables.isNotEmpty) {
        final byVar = _varCtrls.putIfAbsent(
          entry.item.id,
          () => <String, m.TextEditingController>{},
        );
        for (final v in t.variables) {
          if (v.name == 'python') continue;
          final preset = initialVars?[v.name] ?? entry.item.inputs.vars[v.name];
          byVar.putIfAbsent(
            v.name,
            () => m.TextEditingController(text: preset ?? v.defaultValue),
          );
        }
      }
      final seedFiles = initialFiles ?? entry.item.inputs.fileInputs;
      if (seedFiles.isNotEmpty) {
        final bySlot = <String, List<FileBinding>>{};
        for (final e in seedFiles.entries) {
          bySlot[e.key] = e.value
              .map((b) => b.copyWith(path: b.path.trim()))
              .toList();
        }
        if (bySlot.isNotEmpty) {
          _fileInputs[entry.item.id] = bySlot;
        }
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

  List<FileBinding> _ensureList(String itemId, String slotName) {
    final byTask = _fileInputs.putIfAbsent(
      itemId,
      () => <String, List<FileBinding>>{},
    );
    return byTask.putIfAbsent(slotName, () => <FileBinding>[]);
  }

  bool get _canStart {
    if (!widget.enforceRequired) return true;
    for (final entry in widget.entries) {
      final t = entry.task;
      for (final s in t.fileSlots.where((x) => x.required)) {
        final list =
            _fileInputs[entry.item.id]?[s.name] ?? const <FileBinding>[];
        if (list.isEmpty) return false;
      }
      for (final v in t.variables.where(
        (x) => x.required && x.name != 'python',
      )) {
        final c = _varCtrls[entry.item.id]?[v.name];
        final text = c?.text ?? '';
        if (text.trim().isEmpty) return false;
      }
    }
    return true;
  }

  bool _missingRequiredForEntry(_BatchTaskEntry entry) {
    final t = entry.task;
    for (final s in t.fileSlots.where((x) => x.required)) {
      final list = _fileInputs[entry.item.id]?[s.name] ?? const <FileBinding>[];
      if (list.isEmpty) return true;
    }
    for (final v in t.variables.where(
      (x) => x.required && x.name != 'python',
    )) {
      final c = _varCtrls[entry.item.id]?[v.name];
      final text = c?.text ?? '';
      if (text.trim().isEmpty) return true;
    }
    return false;
  }

  RunInputs _normalized() {
    final outFiles = <String, Map<String, List<FileBinding>>>{};
    for (final entry in widget.entries) {
      final slotInputs = _fileInputs[entry.item.id] ?? const {};
      final slots = <String, List<FileBinding>>{};
      for (final s in slotInputs.entries) {
        final list = s.value
            .where((x) => x.path.trim().isNotEmpty)
            .map((x) => x.copyWith(path: x.path.trim()))
            .toList();
        slots[s.key] = list;
      }
      if (slots.isNotEmpty || entry.task.fileSlots.isNotEmpty) {
        outFiles[entry.item.id] = slots;
      }
    }

    final outVars = <String, Map<String, String>>{};
    for (final entry in widget.entries) {
      final t = entry.task;
      if (t.variables.isEmpty) continue;
      final byVar = _varCtrls[entry.item.id];
      if (byVar == null) continue;
      outVars[entry.item.id] = <String, String>{
        for (final v in t.variables)
          if (v.name != 'python') v.name: (byVar[v.name]?.text ?? ''),
      };
    }

    return RunInputs(fileInputs: outFiles, vars: outVars);
  }

  Future<void> _pickFiles(_BatchTaskEntry entry, FileSlot slot) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: slot.multiple,
      dialogTitle: '选择文件：${entry.displayName} / ${slot.name}',
    );
    if (result == null) return;
    final picked = result.paths.whereType<String>().toList();
    if (picked.isEmpty) return;
    setState(() {
      final list = _ensureList(entry.item.id, slot.name);
      if (slot.multiple) {
        for (final x in picked) {
          if (list.every((b) => b.path != x)) {
            list.add(FileBinding(type: FileBindingType.localPath, path: x));
          }
        }
      } else {
        list
          ..clear()
          ..add(
            FileBinding(type: FileBindingType.localPath, path: picked.first),
          );
      }
    });
  }

  Future<void> _addLocalPath(_BatchTaskEntry entry, FileSlot slot) async {
    final path = await _promptPath(
      title: '输入本地路径：${entry.displayName} / ${slot.name}',
      hintText: '例如：/home/user/package.tar.gz 或 C:\\path\\file.zip',
    );
    if (path == null || path.trim().isEmpty) return;
    setState(() {
      final list = _ensureList(entry.item.id, slot.name);
      if (slot.multiple) {
        if (list.every((b) => b.path != path.trim())) {
          list.add(
            FileBinding(type: FileBindingType.localPath, path: path.trim()),
          );
        }
      } else {
        list
          ..clear()
          ..add(
            FileBinding(type: FileBindingType.localPath, path: path.trim()),
          );
      }
    });
  }

  Future<void> _addControlPath(_BatchTaskEntry entry, FileSlot slot) async {
    final path = await _promptPath(
      title: '输入控制端路径：${entry.displayName} / ${slot.name}',
      hintText: '例如：/opt/packages/app.tar.gz',
    );
    if (path == null || path.trim().isEmpty) return;
    setState(() {
      final list = _ensureList(entry.item.id, slot.name);
      if (slot.multiple) {
        if (list.every((b) => b.path != path.trim())) {
          list.add(
            FileBinding(type: FileBindingType.controlPath, path: path.trim()),
          );
        }
      } else {
        list
          ..clear()
          ..add(
            FileBinding(type: FileBindingType.controlPath, path: path.trim()),
          );
      }
    });
  }

  Future<void> _addScriptOutput(
    _BatchTaskEntry entry,
    FileSlot slot,
    int taskIndex,
  ) async {
    final binding = await _pickScriptOutput(taskIndex);
    if (binding == null) return;
    setState(() {
      final list = _ensureList(entry.item.id, slot.name);
      if (slot.multiple) {
        if (list.every((b) => b.path != binding.path)) {
          list.add(binding);
        }
      } else {
        list
          ..clear()
          ..add(binding);
      }
    });
  }

  Future<FileBinding?> _pickScriptOutput(int taskIndex) async {
    final options = <_ScriptOutputChoice>[];
    for (var i = 0; i < widget.entries.length; i++) {
      if (i >= taskIndex) break;
      final entry = widget.entries[i];
      final t = entry.task;
      if (!t.isLocalScript || t.outputs.isEmpty) continue;
      for (final o in t.outputs) {
        options.add(_ScriptOutputChoice(entry: entry, output: o, index: i));
      }
    }

    if (options.isEmpty) {
      await showAppErrorDialog(
        context,
        const AppException(
          code: AppErrorCode.validation,
          title: '无可用脚本产物',
          message: '当前任务之前没有带产物的脚本任务。',
          suggestion: '请先添加并执行产生产物的脚本任务。',
        ),
      );
      return null;
    }

    return showDialog<FileBinding>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('选择脚本产物'),
          content: SizedBox(
            width: 560.w,
            height: 360.h,
            child: ListView.builder(
              itemCount: options.length,
              itemBuilder: (context, i) {
                final o = options[i];
                return m.ListTile(
                  title: Text('${o.entry.displayName} / ${o.output.name}'),
                  subtitle: Text(o.output.path).muted(),
                  onTap: () => Navigator.of(context).pop(
                    FileBinding(
                      type: FileBindingType.localOutput,
                      path: o.output.path,
                      sourceTaskId: o.entry.item.id,
                      sourceOutput: o.output.name,
                    ),
                  ),
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
      },
    );
  }

  Future<String?> _promptPath({required String title, String? hintText}) async {
    final controller = m.TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: m.TextField(
            controller: controller,
            decoration: m.InputDecoration(hintText: hintText),
            autofocus: true,
          ),
          actions: [
            OutlineButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            PrimaryButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  void _remove(_BatchTaskEntry entry, FileSlot slot, FileBinding binding) {
    setState(() {
      final list = _ensureList(entry.item.id, slot.name);
      list.removeWhere((b) => b.type == binding.type && b.path == binding.path);
      if (list.isEmpty) {
        _fileInputs[entry.item.id]?.remove(slot.name);
        if ((_fileInputs[entry.item.id]?.isEmpty ?? false)) {
          _fileInputs.remove(entry.item.id);
        }
      }
    });
  }

  void _clear(_BatchTaskEntry entry, FileSlot slot) {
    setState(() {
      _fileInputs[entry.item.id]?.remove(slot.name);
      if ((_fileInputs[entry.item.id]?.isEmpty ?? false)) {
        _fileInputs.remove(entry.item.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    final selected = entries.isEmpty ? null : entries[_selectedIndex];
    final selectedVars =
        selected?.task.variables.where((v) => v.name != 'python').toList() ??
        const <TaskVariable>[];

    return AlertDialog(
      title: const Text('选择运行输入'),
      content: SizedBox(
        width: 980.w,
        height: 560.h,
        child: Row(
          children: [
            SizedBox(
              width: 240.w,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('任务列表').p(),
                  SizedBox(height: 6.h),
                  Expanded(
                    child: m.ListView.separated(
                      itemCount: entries.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final entry = entries[i];
                        final missing = _missingRequiredForEntry(entry);
                        final selectedItem = _selectedIndex == i;
                        return m.Material(
                          color: selectedItem
                              ? m.Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.06)
                              : Colors.transparent,
                          child: m.InkWell(
                            onTap: () => setState(() => _selectedIndex = i),
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                vertical: 6.h,
                                horizontal: 8.w,
                              ),
                              child: Row(
                                children: [
                                  Text('${i + 1}.').muted(),
                                  SizedBox(width: 6.w),
                                  Expanded(
                                    child: Text(
                                      entry.displayName,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (missing)
                                    const Icon(
                                      Icons.error_outline,
                                      size: 16,
                                      color: Colors.orange,
                                    )
                                  else
                                    const Icon(
                                      Icons.check_circle_outline,
                                      size: 16,
                                      color: Colors.green,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: selected == null
                  ? const Center(child: Text('暂无任务'))
                  : m.ListView(
                      children: [
                        Text(selected.displayName).p(),
                        SizedBox(height: 6.h),
                        if (selectedVars.isNotEmpty) ...[
                          for (final v in selectedVars) ...[
                            m.TextField(
                              controller: _varCtrls[selected.item.id]?[v.name],
                              decoration: m.InputDecoration(
                                labelText: v.required
                                    ? '${v.name}（必填）'
                                    : v.name,
                                helperText: v.description.trim().isEmpty
                                    ? null
                                    : v.description.trim(),
                              ),
                              minLines: 1,
                              maxLines: 3,
                              keyboardType: m.TextInputType.multiline,
                              onChanged: (_) => setState(() {}),
                            ),
                            SizedBox(height: 8.h),
                          ],
                          SizedBox(height: 6.h),
                        ],
                        if (selected.task.fileSlots.isEmpty)
                          Padding(
                            padding: EdgeInsets.only(bottom: 8.h),
                            child: Text('该任务没有文件槽位。').muted(),
                          ),
                        for (final slot in selected.task.fileSlots) ...[
                          _SlotRow(
                            slot: slot,
                            selectedBindings:
                                _fileInputs[selected.item.id]?[slot.name] ??
                                const [],
                            onPick: () => _pickFiles(selected, slot),
                            onAddLocal: () => _addLocalPath(selected, slot),
                            onAddControl: () => _addControlPath(selected, slot),
                            onAddOutput: () => _addScriptOutput(
                              selected,
                              slot,
                              selected.index,
                            ),
                            onClear: () => _clear(selected, slot),
                            onRemove: (binding) =>
                                _remove(selected, slot, binding),
                          ),
                          SizedBox(height: 10.h),
                        ],
                      ],
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
          onPressed: _canStart
              ? () => Navigator.of(context).pop(_normalized())
              : null,
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

class _BatchSnapshotsDialog extends StatefulWidget {
  final Batch batch;
  final List<_BatchTaskEntry> entries;
  final Server? control;

  const _BatchSnapshotsDialog({
    required this.batch,
    required this.entries,
    required this.control,
  });

  @override
  State<_BatchSnapshotsDialog> createState() => _BatchSnapshotsDialogState();
}

class _BatchSnapshotsDialogState extends State<_BatchSnapshotsDialog> {
  @override
  void initState() {
    super.initState();
    final controller = Get.find<BatchesController>();
    // ignore: unawaited_futures
    controller.loadSnapshots();
  }

  Future<String?> _promptSnapshotName({
    required String title,
    String? initial,
  }) async {
    final ctrl = m.TextEditingController(text: initial ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: m.TextField(
          controller: ctrl,
          decoration: const m.InputDecoration(hintText: '请输入快照名称'),
          autofocus: true,
        ),
        actions: [
          OutlineButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          PrimaryButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  Future<void> _startRunWithInputs(RunInputs inputs) async {
    final controller = Get.find<BatchesController>();
    try {
      await controller.startRunWithInputs(inputs);
      if (mounted) Navigator.of(context).pop();
    } on AppException catch (e) {
      if (e.code == AppErrorCode.validation &&
          e.message.contains('检测到控制端环境不支持')) {
        if (!mounted) return;
        final allow = await _maybeConfirmUnsupportedControlAutoInstall(
          context,
          widget.control!,
        );
        if (allow == true) {
          await controller.startRunWithInputs(
            inputs,
            allowUnsupportedControlOsAutoInstall: true,
          );
          if (mounted) Navigator.of(context).pop();
        }
      } else if (mounted) {
        await showAppErrorDialog(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BatchesController>();
    final now = DateTime.now();

    return AlertDialog(
      title: const Text('参数快照'),
      content: SizedBox(
        width: 760.w,
        height: 420.h,
        child: Obx(() {
          final snaps = controller.snapshots;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  GhostButton(
                    onPressed: () async {
                      final name = await _promptSnapshotName(
                        title: '基于当前配置创建快照',
                        initial: '当前配置 ${formatDateTime(now)}',
                      );
                      if (name == null || name.trim().isEmpty) return;
                      final inputs = controller.buildInputsFromBatch(
                        widget.batch,
                      );
                      await controller.saveSnapshot(
                        batch: widget.batch,
                        name: name,
                        inputs: inputs,
                      );
                    },
                    child: const Text('基于当前配置创建'),
                  ),
                  SizedBox(width: 8.w),
                  GhostButton(
                    onPressed: () async {
                      final last = await controller.readLastInputs(
                        widget.batch.id,
                      );
                      if (last == null) {
                        if (!mounted) return;
                        await showDialog<void>(
                          context: context,
                          builder: (context) => const AlertDialog(
                            title: Text('无上次输入'),
                            content: Text('未找到上次执行的输入记录。'),
                          ),
                        );
                        return;
                      }
                      final name = await _promptSnapshotName(
                        title: '基于上次运行创建快照',
                        initial: '上次运行 ${formatDateTime(now)}',
                      );
                      if (name == null || name.trim().isEmpty) return;
                      await controller.saveSnapshot(
                        batch: widget.batch,
                        name: name,
                        inputs: last,
                      );
                    },
                    child: const Text('基于上次运行创建'),
                  ),
                  const Spacer(),
                  GhostButton(
                    density: ButtonDensity.icon,
                    onPressed: controller.loadSnapshots,
                    child: const Icon(Icons.refresh, size: 18),
                  ),
                ],
              ),
              SizedBox(height: 12.h),
              Expanded(
                child: snaps.isEmpty
                    ? const Center(child: Text('暂无快照'))
                    : m.ListView.separated(
                        itemCount: snaps.length,
                        separatorBuilder: (context, index) =>
                            const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final s = snaps[i];
                          return m.ListTile(
                            title: Text(s.name),
                            subtitle: Text(formatDateTime(s.createdAt)).muted(),
                            trailing: Wrap(
                              spacing: 6.w,
                              children: [
                                GhostButton(
                                  onPressed: () async {
                                    final inputs = await showDialog<RunInputs>(
                                      context: context,
                                      builder: (context) => _BatchInputsDialog(
                                        entries: widget.entries,
                                        initialInputs: s.inputs,
                                      ),
                                    );
                                    if (inputs == null) return;
                                    if (!mounted) return;
                                    await _startRunWithInputs(inputs);
                                  },
                                  child: const Text('运行'),
                                ),
                                GhostButton(
                                  onPressed: () async {
                                    try {
                                      await controller.updateBatchTaskInputs(
                                        widget.batch,
                                        s.inputs,
                                      );
                                      if (!mounted) return;
                                      showToast(
                                        context: context,
                                        builder: (context, overlay) => Card(
                                          child: Padding(
                                            padding: EdgeInsets.all(12.r),
                                            child: const Text('快照已应用到批次'),
                                          ),
                                        ),
                                      );
                                    } on AppException catch (e) {
                                      if (mounted) {
                                        await showAppErrorDialog(context, e);
                                      }
                                    }
                                  },
                                  child: const Text('应用'),
                                ),
                                GhostButton(
                                  onPressed: () async {
                                    final name = await _promptSnapshotName(
                                      title: '重命名快照',
                                      initial: s.name,
                                    );
                                    if (name == null || name.trim().isEmpty) {
                                      return;
                                    }
                                    await controller.renameSnapshot(
                                      batch: widget.batch,
                                      snapshot: s,
                                      name: name,
                                    );
                                  },
                                  child: const Text('重命名'),
                                ),
                                DestructiveButton(
                                  onPressed: () async {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: const Text('删除快照？'),
                                        content: Text('确认删除 “${s.name}”？'),
                                        actions: [
                                          OutlineButton(
                                            onPressed: () => Navigator.of(
                                              context,
                                            ).pop(false),
                                            child: const Text('取消'),
                                          ),
                                          DestructiveButton(
                                            onPressed: () =>
                                                Navigator.of(context).pop(true),
                                            child: const Text('删除'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok != true) return;
                                    await controller.deleteSnapshot(
                                      batch: widget.batch,
                                      snapshot: s,
                                    );
                                  },
                                  child: const Text('删除'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        }),
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _ScriptOutputChoice {
  final _BatchTaskEntry entry;
  final TaskOutput output;
  final int index;

  const _ScriptOutputChoice({
    required this.entry,
    required this.output,
    required this.index,
  });
}

class _SlotRow extends StatelessWidget {
  final FileSlot slot;
  final List<FileBinding> selectedBindings;
  final VoidCallback onPick;
  final VoidCallback onAddLocal;
  final VoidCallback onAddControl;
  final VoidCallback onAddOutput;
  final VoidCallback onClear;
  final void Function(FileBinding binding) onRemove;

  const _SlotRow({
    required this.slot,
    required this.selectedBindings,
    required this.onPick,
    required this.onAddLocal,
    required this.onAddControl,
    required this.onAddOutput,
    required this.onClear,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final requiredText = slot.required ? '必选' : '可选';
    final multiText = slot.multiple ? '多文件' : '单文件';
    final hasAny = selectedBindings.isNotEmpty;

    String labelFor(FileBinding b) {
      if (b.isLocalOutput) {
        final name = b.sourceOutput == null || b.sourceOutput!.trim().isEmpty
            ? b.path
            : b.sourceOutput!;
        return '产物: $name';
      }
      final prefix = b.isControl ? '控制端' : '本地';
      final name = b.isControl ? b.path : p.basename(b.path);
      return '$prefix: $name';
    }

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
            GhostButton(onPressed: onAddLocal, child: const Text('本地路径')),
            SizedBox(width: 8.w),
            GhostButton(onPressed: onAddControl, child: const Text('控制端路径')),
            SizedBox(width: 8.w),
            GhostButton(onPressed: onAddOutput, child: const Text('脚本产物')),
            SizedBox(width: 8.w),
            GhostButton(
              onPressed: hasAny ? onClear : null,
              child: const Text('清空'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (selectedBindings.isEmpty)
          Text(slot.required ? '（必选）未选择文件' : '未选择').muted()
        else
          Wrap(
            spacing: 8.w,
            runSpacing: 8.h,
            children: [
              for (final binding in selectedBindings)
                m.InputChip(
                  label: Text(labelFor(binding)).mono(),
                  onDeleted: () => onRemove(binding),
                ),
            ],
          ),
      ],
    );
  }
}
