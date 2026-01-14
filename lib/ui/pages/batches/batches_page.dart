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
import '../../utils/layout_metrics.dart';

class BatchesPage extends StatelessWidget {
  const BatchesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.put(BatchesController());

    Widget filter(String value, String label) {
      return Obx(() {
        final selected = controller.filterStatus.value == value;
        return selected
            ? SecondaryButton(
                onPressed: () => controller.filterStatus.value = value,
                child: Text(label),
              )
            : OutlineButton(
                onPressed: () => controller.filterStatus.value = value,
                child: Text(label),
              );
      });
    }

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
                              Expanded(child: Text('批次').p()),
                              PrimaryButton(
                                density: ButtonDensity.icon,
                                onPressed: () async {
                                  final created = await showDialog<Batch>(
                                    context: context,
                                    builder: (context) => _BatchEditDialog(
                                      initial: null,
                                      servers: controller.servers,
                                      tasks: controller.tasks,
                                    ),
                                  );
                                  if (created == null) return;
                                  try {
                                    await controller.upsertBatch(created);
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
                          Wrap(
                            spacing: 8.w,
                            runSpacing: 8.h,
                            children: [
                              filter('all', '全部'),
                              filter(BatchStatus.paused, '暂停'),
                              filter(BatchStatus.running, '运行中'),
                              filter(BatchStatus.ended, '结束'),
                            ],
                          ),
                          SizedBox(height: 12.h),
                          Expanded(
                            child: Obx(() {
                              final items = controller.visibleBatches;
                              if (items.isEmpty) {
                                return const Center(child: Text('暂无批次'));
                              }
                              return m.ListView.builder(
                                itemCount: items.length,
                                itemBuilder: (context, i) {
                                  final b = items[i];
                                  final selected =
                                      controller.selectedBatchId.value == b.id;
                                  final last =
                                      controller.lastRunByBatchId[b.id];
                                  final lastText = last == null
                                      ? '最后 Run: —'
                                      : '最后 Run: ${last.result} · ${_fmtRunTime(last.startedAt)}';
                                  return m.ListTile(
                                    selected: selected,
                                    title: Text(b.name),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          m.CrossAxisAlignment.start,
                                      mainAxisSize: m.MainAxisSize.min,
                                      children: [
                                        Text(
                                          '${b.status} · ${b.managedServerIds.length} 被控端 · ${b.taskOrder.length} 任务',
                                        ).muted(),
                                        Text(lastText).muted(),
                                      ],
                                    ),
                                    trailing: b.status == BatchStatus.running
                                        ? const Icon(Icons.play_arrow)
                                        : null,
                                    onTap: () =>
                                        controller.selectedBatchId.value = b.id,
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
                    final batch = controller.selectedBatch;
                    if (batch == null) {
                      return const Card(
                        child: Center(child: Text('选择一个批次查看详情')),
                      );
                    }
                    return _BatchDetail(batch: batch);
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

class _BatchDetail extends StatelessWidget {
  final Batch batch;

  const _BatchDetail({required this.batch});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BatchesController>();
    final control = controller.serverById(batch.controlServerId);
    final managed = batch.managedServerIds
        .map(controller.serverById)
        .whereType<Server>()
        .toList();
    final tasks = batch.taskOrder
        .map(controller.taskById)
        .whereType<Task>()
        .toList();

    final paused = batch.status == BatchStatus.paused;
    final ended = batch.status == BatchStatus.ended;

    Future<void> onExecute() async {
      try {
        final inputs = await showDialog<Map<String, Map<String, List<String>>>>(
          context: context,
          builder: (context) => _BatchFileInputsDialog(tasks: tasks),
        );
        if (inputs == null) return;
        if (!context.mounted) return;
        final c = control;
        if (c == null) {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '控制端未找到',
            message: '批次配置的 controlServerId 在服务器列表中不存在。',
            suggestion: '编辑批次并重新选择控制端。',
          );
        }
        if (!c.enabled) {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '控制端已禁用',
            message: '控制端 enabled=false，无法执行。',
            suggestion: '在服务器列表中启用控制端，或更换控制端。',
          );
        }

        final allowUnsupported =
            await _maybeConfirmUnsupportedControlAutoInstall(context, c);
        if (allowUnsupported == null) return;
        await controller.startRunWithFiles(
          inputs,
          allowUnsupportedControlOsAutoInstall: allowUnsupported,
        );
      } on AppException catch (e) {
        if (context.mounted) {
          await showAppErrorDialog(context, e);
        }
      }
    }

    Future<void> onExecuteReuseLast() async {
      try {
        final last = await controller.readLastFileInputs(batch.id);
        if (last == null) {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '暂无上次文件选择',
            message: '该批次没有保存过文件选择记录，无法沿用。',
            suggestion: '点击“选择文件并执行”并至少选择一次文件后即可沿用。',
          );
        }
        if (!context.mounted) return;

        final c = control;
        if (c == null) {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '控制端未找到',
            message: '批次配置的 controlServerId 在服务器列表中不存在。',
            suggestion: '编辑批次并重新选择控制端。',
          );
        }
        if (!c.enabled) {
          throw const AppException(
            code: AppErrorCode.validation,
            title: '控制端已禁用',
            message: '控制端 enabled=false，无法执行。',
            suggestion: '在服务器列表中启用控制端，或更换控制端。',
          );
        }

        final allowUnsupported =
            await _maybeConfirmUnsupportedControlAutoInstall(context, c);
        if (allowUnsupported == null) return;

        await controller.startRunWithFiles(
          last,
          allowUnsupportedControlOsAutoInstall: allowUnsupported,
        );
      } on AppException catch (e) {
        if (context.mounted) {
          await showAppErrorDialog(context, e);
        }
      }
    }

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.r),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(batch.name).h2()),
                if (paused)
                  GhostButton(
                    onPressed: () async {
                      final updated = await showDialog<Batch>(
                        context: context,
                        builder: (context) => _BatchEditDialog(
                          initial: batch,
                          servers: controller.servers,
                          tasks: controller.tasks,
                        ),
                      );
                      if (updated == null) return;
                      try {
                        await controller.upsertBatch(updated);
                      } on AppException catch (e) {
                        if (context.mounted) {
                          await showAppErrorDialog(context, e);
                        }
                      }
                    },
                    child: const Text('编辑'),
                  ),
                SizedBox(width: 8.w),
                OutlineButton(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('强制解锁/重置为暂停？'),
                        content: const Text('将删除锁文件并把批次状态重置为 paused（异常恢复入口）。'),
                        actions: [
                          OutlineButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text('取消'),
                          ),
                          DestructiveButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            child: const Text('确定'),
                          ),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    try {
                      await controller.forceUnlockAndReset();
                    } on AppException catch (e) {
                      if (context.mounted) {
                        await showAppErrorDialog(context, e);
                      }
                    }
                  },
                  child: const Text('强制解锁/重置'),
                ),
                SizedBox(width: 8.w),
                if (paused)
                  DestructiveButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('删除批次？'),
                          content: Text('将删除：${batch.name}'),
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
                        await controller.deleteSelectedBatch();
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
            Text('状态: ${batch.status}').mono(),
            SizedBox(height: 6.h),
            Text('控制端: ${control?.name ?? '未找到'}').mono(),
            SizedBox(height: 6.h),
            Text('被控端: ${managed.length}').mono(),
            SizedBox(height: 6.h),
            Text('任务数: ${tasks.length}').mono(),
            SizedBox(height: 12.h),
            Row(
              children: [
                Expanded(child: Text('执行').p()),
                PrimaryButton(
                  onPressed: paused ? onExecute : null,
                  child: const Text('选择文件并执行'),
                ),
                SizedBox(width: 8.w),
                OutlineButton(
                  onPressed: paused ? onExecuteReuseLast : null,
                  child: const Text('沿用上次文件执行'),
                ),
                SizedBox(width: 8.w),
                OutlineButton(
                  onPressed: ended ? controller.resetToPaused : null,
                  child: const Text('重置为暂停'),
                ),
              ],
            ),
            if (ended) ...[
              SizedBox(height: 8.h),
              const Text('提示：批次已结束，请先“重置为暂停”后再编辑/执行。').muted(),
            ],
            SizedBox(height: 8.h),
            FutureBuilder(
              future: controller.readLockInfo(),
              builder: (context, snapshot) {
                final lock = snapshot.data;
                if (lock == null) return const SizedBox.shrink();
                return Text(
                  '锁: run=${lock.runId.substring(0, 8)} pid=${lock.pid} at=${formatDateTime(lock.createdAt)}',
                ).muted();
              },
            ),
            SizedBox(height: 16.h),
            Expanded(
              child: _RunAndLogsSection(batch: batch, tasks: tasks),
            ),
          ],
        ),
      ),
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

class _RunAndLogsSection extends StatelessWidget {
  final Batch batch;
  final List<Task> tasks;

  const _RunAndLogsSection({required this.batch, required this.tasks});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BatchesController>();
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final controlsWidth = (maxW.isFinite ? maxW * 0.44 : 420.0).clamp(
          320.0,
          520.0,
        );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: controlsWidth,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Obx(() {
                      final run = controller.selectedRun;
                      if (run == null) return const SizedBox.shrink();
                      final endedAt = run.endedAt == null
                          ? '—'
                          : formatDateTime(run.endedAt!);
                      final biz = run.bizStatus;
                      return Card(
                        child: Padding(
                          padding: EdgeInsets.all(12.r),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Run: ${run.status} · ${run.result} · started=${formatDateTime(run.startedAt)} · ended=$endedAt',
                              ).mono(),
                              if ((run.errorSummary ?? '')
                                  .trim()
                                  .isNotEmpty) ...[
                                SizedBox(height: 6.h),
                                Text('错误: ${run.errorSummary}').muted(),
                              ],
                              if (biz != null) ...[
                                SizedBox(height: 6.h),
                                Text(
                                  '业务状态: ${biz.status} ${biz.message}'.trim(),
                                ).muted(),
                              ],
                            ],
                          ),
                        ),
                      );
                    }),
                    SizedBox(height: 12.h),
                    Text('任务进度').p(),
                    SizedBox(height: 8.h),
                    Obx(() {
                      final run = controller.selectedRun;
                      final results =
                          run?.taskResults ?? const <TaskRunResult>[];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _TaskProgressBar(
                            tasks: tasks,
                            results: results,
                            selectedIndex: controller.selectedTaskIndex.value,
                            onSelect: (i) =>
                                controller.selectedTaskIndex.value = i,
                          ),
                          SizedBox(height: 8.h),
                          Steps(
                            children: [
                              for (var i = 0; i < tasks.length; i++)
                                StepItem(
                                  title: Text(tasks[i].name),
                                  content: [
                                    Text(
                                      _taskStatusText(results, tasks[i].id),
                                    ).muted(),
                                  ],
                                ),
                            ],
                          ),
                        ],
                      );
                    }),
                    SizedBox(height: 16.h),
                    Row(
                      children: [
                        Text('Run').p(),
                        SizedBox(width: 12.w),
                        Expanded(
                          child: Obx(() {
                            final items = controller.runs;
                            if (items.isEmpty) {
                              return const Text('暂无 Run').muted();
                            }
                            return Wrap(
                              spacing: 8.w,
                              runSpacing: 8.h,
                              children: [
                                for (final r in items)
                                  _PickButton(
                                    selected:
                                        controller.selectedRunId.value == r.id,
                                    onPressed: () =>
                                        controller.selectedRunId.value = r.id,
                                    child: Text(formatDateTime(r.startedAt)),
                                  ),
                              ],
                            );
                          }),
                        ),
                      ],
                    ),
                    SizedBox(height: 12.h),
                    Row(
                      children: [
                        Text('任务').p(),
                        SizedBox(width: 12.w),
                        Expanded(
                          child: Obx(() {
                            return Wrap(
                              spacing: 8.w,
                              runSpacing: 8.h,
                              children: [
                                for (var i = 0; i < tasks.length; i++)
                                  _PickButton(
                                    selected:
                                        controller.selectedTaskIndex.value == i,
                                    onPressed: () =>
                                        controller.selectedTaskIndex.value = i,
                                    child: Text('${i + 1}'),
                                  ),
                              ],
                            );
                          }),
                        ),
                      ],
                    ),
                    SizedBox(height: 12.h),
                    const Text('提示：日志默认只渲染尾部，避免大文件卡顿。').muted(),
                  ],
                ),
              ),
            ),
            SizedBox(width: 16.w),
            Expanded(
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(12.r),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text('执行日志').p()),
                          Obx(
                            () => Text(
                              '最后 ${controller.logMaxLines.value} 行',
                            ).muted(),
                          ),
                          SizedBox(width: 12.w),
                          OutlineButton(
                            onPressed: controller.refreshLog,
                            child: const Text('刷新'),
                          ),
                          SizedBox(width: 8.w),
                          Obx(() {
                            final canMore =
                                controller.logMaxLines.value < 20000;
                            return OutlineButton(
                              onPressed: canMore
                                  ? controller.loadMoreLog
                                  : null,
                              child: const Text('加载更多'),
                            );
                          }),
                        ],
                      ),
                      SizedBox(height: 6.h),
                      Obx(() {
                        final bytes = controller.currentLogFileSize.value;
                        if (bytes == null) {
                          return const Text('暂无日志文件。').muted();
                        }
                        final kb = bytes / 1024.0;
                        return Text(
                          'log 文件大小: ${kb.toStringAsFixed(1)} KB',
                        ).muted();
                      }),
                      SizedBox(height: 8.h),
                      Expanded(
                        child: Obx(() {
                          final text = controller.currentLog.value;
                          return CodeSnippet(
                            code: Text(text.isEmpty ? '（空）' : text).mono(),
                          );
                        }),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _taskStatusText(List<TaskRunResult> results, String taskId) {
    final r = results.firstWhereOrNull((x) => x.taskId == taskId);
    if (r == null) return '等待';
    return switch (r.status) {
      TaskExecStatus.waiting => '等待',
      TaskExecStatus.running => '执行中',
      TaskExecStatus.success => '成功 (exit=${r.exitCode ?? 0})',
      TaskExecStatus.failed => '失败 (exit=${r.exitCode ?? -1})',
      _ => r.status,
    };
  }
}

class _TaskProgressBar extends StatelessWidget {
  final List<Task> tasks;
  final List<TaskRunResult> results;
  final int selectedIndex;
  final void Function(int index) onSelect;

  const _TaskProgressBar({
    required this.tasks,
    required this.results,
    required this.selectedIndex,
    required this.onSelect,
  });

  TaskRunResult? _resultFor(String taskId) =>
      results.firstWhereOrNull((r) => r.taskId == taskId);

  m.Color _colorFor(String status) {
    return switch (status) {
      TaskExecStatus.running => m.Colors.blue.shade400,
      TaskExecStatus.success => m.Colors.green.shade600,
      TaskExecStatus.failed => m.Colors.red.shade600,
      _ => m.Colors.grey.shade600,
    };
  }

  @override
  Widget build(BuildContext context) {
    return m.SingleChildScrollView(
      scrollDirection: m.Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < tasks.length; i++) ...[
            _TaskNode(
              index: i,
              selected: selectedIndex == i,
              color: _colorFor(
                _resultFor(tasks[i].id)?.status ?? TaskExecStatus.waiting,
              ),
              onTap: () => onSelect(i),
            ),
            if (i < tasks.length - 1)
              Container(
                width: 28.w,
                height: 2.h,
                margin: EdgeInsets.symmetric(horizontal: 6.w),
                color: m.Colors.grey.shade700,
              ),
          ],
        ],
      ),
    );
  }
}

class _TaskNode extends StatelessWidget {
  final int index;
  final bool selected;
  final m.Color color;
  final VoidCallback onTap;

  const _TaskNode({
    required this.index,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return m.InkWell(
      onTap: onTap,
      borderRadius: m.BorderRadius.circular(999),
      child: Container(
        width: 28.w,
        height: 28.w,
        alignment: m.Alignment.center,
        decoration: m.BoxDecoration(
          color: color,
          shape: m.BoxShape.circle,
          border: selected
              ? m.Border.all(color: m.Colors.white, width: 2)
              : m.Border.all(color: m.Colors.transparent, width: 2),
        ),
        child: Text('${index + 1}').mono(),
      ),
    );
  }
}

class _PickButton extends StatelessWidget {
  final bool selected;
  final VoidCallback onPressed;
  final Widget child;

  const _PickButton({
    required this.selected,
    required this.onPressed,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (selected) {
      return SecondaryButton(onPressed: onPressed, child: child);
    }
    return OutlineButton(onPressed: onPressed, child: child);
  }
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

String _fmtRunTime(DateTime dt) {
  final d = dt.toLocal();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

class _BatchFileInputsDialog extends StatefulWidget {
  final List<Task> tasks;

  const _BatchFileInputsDialog({required this.tasks});

  @override
  State<_BatchFileInputsDialog> createState() => _BatchFileInputsDialogState();
}

class _BatchFileInputsDialogState extends State<_BatchFileInputsDialog> {
  final Map<String, Map<String, List<String>>> _inputs = {};

  List<String> _ensureList(String taskId, String slotName) {
    final byTask = _inputs.putIfAbsent(taskId, () => <String, List<String>>{});
    return byTask.putIfAbsent(slotName, () => <String>[]);
  }

  bool get _canStart {
    for (final t in widget.tasks) {
      for (final s in t.fileSlots.where((x) => x.required)) {
        final list = _inputs[t.id]?[s.name] ?? const <String>[];
        if (list.isEmpty) return false;
      }
    }
    return true;
  }

  Map<String, Map<String, List<String>>> _normalized() {
    final out = <String, Map<String, List<String>>>{};
    for (final entry in _inputs.entries) {
      final slots = <String, List<String>>{};
      for (final s in entry.value.entries) {
        final list = s.value.where((x) => x.trim().isNotEmpty).toList();
        if (list.isEmpty) continue;
        slots[s.key] = list;
      }
      if (slots.isEmpty) continue;
      out[entry.key] = slots;
    }
    return out;
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
        _inputs[task.id]?.remove(slot.name);
        if ((_inputs[task.id]?.isEmpty ?? false)) {
          _inputs.remove(task.id);
        }
      }
    });
  }

  void _clear(Task task, FileSlot slot) {
    setState(() {
      _inputs[task.id]?.remove(slot.name);
      if ((_inputs[task.id]?.isEmpty ?? false)) {
        _inputs.remove(task.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择运行输入文件'),
      content: SizedBox(
        width: 760.w,
        height: 560.h,
        child: m.ListView(
          children: [
            const Text('说明：必选槽位未选择文件将无法开始执行。').muted(),
            SizedBox(height: 12.h),
            for (var ti = 0; ti < widget.tasks.length; ti++) ...[
              if (ti > 0) const Divider(),
              Text(widget.tasks[ti].name).p(),
              SizedBox(height: 6.h),
              if (widget.tasks[ti].fileSlots.isEmpty)
                Padding(
                  padding: EdgeInsets.only(bottom: 8.h),
                  child: Text('该任务没有文件槽位。').muted(),
                ),
              for (final slot in widget.tasks[ti].fileSlots) ...[
                _SlotRow(
                  slot: slot,
                  selectedPaths:
                      _inputs[widget.tasks[ti].id]?[slot.name] ?? const [],
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
