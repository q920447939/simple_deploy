import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../model/batch.dart';
import '../../model/file_binding.dart';
import '../../model/playbook_meta.dart';
import '../../model/run.dart';
import '../../model/run_inputs.dart';
import '../../model/server.dart';
import '../../model/task.dart';
import '../../model/upload_progress.dart';
import '../../services/core/app_error.dart';
import '../../services/core/app_logger.dart';
import '../../storage/atomic_file.dart';
import '../../storage/batch_lock.dart';
import '../../storage/batches_store.dart';
import '../../storage/playbooks_store.dart';
import '../../storage/project_paths.dart';
import '../../storage/runs_store.dart';
import '../../storage/servers_store.dart';
import '../../storage/tasks_store.dart';
import '../offline_assets/offline_assets.dart';
import '../ssh/ssh_service.dart';
import 'control_node_bootstrapper.dart';

class _BatchTaskEntry {
  final BatchTaskItem item;
  final Task task;

  const _BatchTaskEntry({required this.item, required this.task});
}

class RunEngine {
  final SshService ssh;
  final AppLogger logger;
  final Uuid uuid;
  final Directory projectsRoot;

  RunEngine({
    required this.ssh,
    required this.logger,
    required this.uuid,
    required this.projectsRoot,
  });

  Future<void> startBatchRun({
    required String projectId,
    required Batch batch,
    required RunInputs inputs,
    bool allowUnsupportedControlOsAutoInstall = false,
  }) async {
    final pp = ProjectPaths(projectsRoot: projectsRoot, projectId: projectId);
    await pp.ensureExists();

    final serversStore = ServersStore(paths: pp, logger: logger);
    final tasksStore = TasksStore(paths: pp, logger: logger);
    final playbooksStore = PlaybooksStore(paths: pp, logger: logger);
    final batchesStore = BatchesStore(paths: pp, logger: logger);
    final runsStore = RunsStore(paths: pp, logger: logger);

    final allServers = await serversStore.list();
    final allTasks = await tasksStore.list();
    final allPlaybooks = await playbooksStore.listMeta();

    final controlServer = _firstWhereOrNull(
      allServers,
      (s) => s.id == batch.controlServerId,
    );
    if (controlServer == null) {
      throw const AppException(
        code: AppErrorCode.unknown,
        title: '控制端未找到',
        message: '批次配置的 controlServerId 在 servers.json 中不存在。',
        suggestion: '编辑批次并重新选择控制端。',
      );
    }
    if (!controlServer.enabled) {
      throw const AppException(
        code: AppErrorCode.unknown,
        title: '控制端已禁用',
        message: '控制端 enabled=false，无法执行。',
        suggestion: '在服务器列表中启用控制端，或更换控制端。',
      );
    }

    final managedServers = batch.managedServerIds
        .map((id) => _firstWhereOrNull(allServers, (s) => s.id == id))
        .whereType<Server>()
        .where((s) => s.enabled)
        .toList();
    if (managedServers.isEmpty) {
      throw const AppException(
        code: AppErrorCode.unknown,
        title: '被控端为空',
        message: '批次未选择可用的被控端（enabled=true）。',
        suggestion: '编辑批次并选择至少 1 个被控端。',
      );
    }

    final orderedEntries = _resolveOrderedEntries(batch, allTasks);
    if (orderedEntries.isEmpty) {
      throw const AppException(
        code: AppErrorCode.unknown,
        title: '任务为空',
        message: '批次任务顺序为空或任务不存在。',
        suggestion: '编辑批次并选择至少 1 个任务。',
      );
    }
    final orderedTasks = [for (final e in orderedEntries) e.task];

    final runId = uuid.v4();
    final pythonPath = batch.pythonPath.trim().isEmpty
        ? '/usr/bin/python3'
        : batch.pythonPath.trim();
    final nextSeq = batch.runSeq + 1;
    final lockInfo = BatchLockInfo(
      runId: runId,
      pid: pid,
      createdAt: DateTime.now(),
    );

    await BatchLock.acquire(pp.batchLockFile(batch.id), lockInfo);
    logger.info(
      'run.lock.acquired',
      data: {'project_id': projectId, 'batch_id': batch.id, 'run_id': runId},
    );

    final effectiveVarsByItemId = _buildEffectiveVarsByItemId(
      orderedEntries,
      inputs.vars,
      pythonPath: pythonPath,
    );

    Run run = Run(
      id: runId,
      projectId: projectId,
      batchId: batch.id,
      seq: nextSeq,
      startedAt: DateTime.now(),
      endedAt: null,
      systemStatus: TaskExecStatus.running,
      systemError: null,
      status: RunStatus.running,
      result: RunResult.failed,
      taskResults: [
        for (final e in orderedEntries)
          TaskRunResult(
            batchTaskId: e.item.id,
            taskId: e.task.id,
            status: TaskExecStatus.waiting,
            exitCode: null,
            fileInputs: null,
            vars: effectiveVarsByItemId[e.item.id],
            error: null,
          ),
      ],
      ansibleSummary: null,
      bizStatus: null,
      errorSummary: null,
    );

    final updatedBatch = batch.copyWith(
      status: BatchStatus.running,
      updatedAt: DateTime.now(),
      lastRunId: runId,
      runSeq: nextSeq,
      pythonPath: pythonPath,
    );

    Future<void> Function(String) logSystem = (_) async {};
    File? snapshotFile;
    Directory? snapshotDir;
    Map<String, Object?>? snapshot;

    try {
      await batchesStore.upsert(updatedBatch);
      await runsStore.write(run);

      final systemLog = pp.systemLogFile(runId);
      await systemLog.parent.create(recursive: true);
      logSystem = (String message) async {
        final ts = DateTime.now().toIso8601String();
        await systemLog.writeAsString(
          '[$ts] $message\n',
          mode: FileMode.writeOnlyAppend,
          flush: true,
        );
      };

      snapshotDir = pp.runSnapshotDirFor(batch.id, nextSeq);
      await snapshotDir.create(recursive: true);
      snapshotFile = pp.runSnapshotFileFor(batch.id, nextSeq);
      snapshot = <String, Object?>{
        'run_id': runId,
        'batch_id': batch.id,
        'seq': nextSeq,
        'created_at': DateTime.now().toIso8601String(),
        'python_path': pythonPath,
        'control_server': _snapshotServer(controlServer),
        'managed_servers': managedServers
            .map((s) => _snapshotServer(s))
            .toList(),
        'task_order': batch.taskOrder,
        'task_items': [
          for (var i = 0; i < orderedEntries.length; i++)
            <String, Object?>{
              'item_id': orderedEntries[i].item.id,
              'task_id': orderedEntries[i].task.id,
              'name': orderedEntries[i].item.name.isNotEmpty
                  ? orderedEntries[i].item.name
                  : orderedEntries[i].task.name,
              'index': i,
              'type': orderedEntries[i].task.type,
              'enabled': orderedEntries[i].item.enabled,
              'playbook_id': orderedEntries[i].task.playbookId,
            },
        ],
        'inputs': inputs.toJson(),
        'resolved_vars': effectiveVarsByItemId,
        'resolved_files': const <String, Object?>{},
        'file_meta': const <String, Object?>{},
        'status': 'preparing',
      };
      final snap = snapshot;
      final snapFile = snapshotFile;
      final snapDir = snapshotDir;
      await _writeSnapshot(snapFile, snap);
      await logSystem('run start: batch=${batch.id} seq=$nextSeq');

      _assertTaskOrderOrThrow(orderedTasks);

      if (orderedEntries.any((e) => e.task.isLocalScript)) {
        await logSystem('prepare stage for local scripts');
        final preStage = await _prepareStage(
          pp: pp,
          runId: runId,
          entries: orderedEntries,
          playbooks: allPlaybooks,
          remoteFilesMappingByItemId:
              const <String, Map<String, List<String>>>{},
          managedServers: managedServers,
          projectId: projectId,
          effectiveVarsByItemId: effectiveVarsByItemId,
          pythonPath: pythonPath,
        );

        final localRun = await _runLocalScripts(
          pp: pp,
          runId: runId,
          entries: orderedEntries,
          stage: preStage.stage,
          remoteRunDir: preStage.remoteRunDir,
          effectiveVarsByItemId: effectiveVarsByItemId,
          run: run,
          runsStore: runsStore,
        );
        run = localRun.run;
        if (localRun.aborted) {
          run = run.copyWith(
            systemStatus: TaskExecStatus.failed,
            systemError: run.errorSummary ?? 'local_script failed',
          );
          run = _markPendingTasksBlocked(run);
          await runsStore.write(run);
          snap['status'] = 'failed';
          snap['error'] = run.errorSummary ?? 'local_script failed';
          await _writeSnapshot(snapFile, snap);
          return;
        }
      }

      await logSystem('prepare input files');
      final preparedInputs = await _persistFileInputsToArtifacts(
        pp: pp,
        runId: runId,
        orderedEntries: orderedEntries,
        fileInputs: inputs.fileInputs,
        effectiveVarsByItemId: effectiveVarsByItemId,
      );

      run = run.copyWith(
        taskResults: [
          for (var i = 0; i < orderedEntries.length; i++)
            run.taskResults[i].copyWith(
              fileInputs: preparedInputs
                  .remoteFilesMappingByItemId[orderedEntries[i].item.id],
            ),
        ],
      );
      await runsStore.write(run);

      await logSystem('copy snapshot files');
      final snapshotFilesMeta = await _copySnapshotFilesFromArtifacts(
        pp.runArtifactsFor(runId),
        snapDir,
      );
      snap['resolved_files'] = preparedInputs.remoteFilesMappingByItemId;
      snap['file_meta'] = snapshotFilesMeta;
      snap['status'] = 'staged';
      await _writeSnapshot(snapFile, snap);

      await logSystem('prepare bundle stage');
      final stagePrepared = await _prepareStage(
        pp: pp,
        runId: runId,
        entries: orderedEntries,
        playbooks: allPlaybooks,
        remoteFilesMappingByItemId: preparedInputs.remoteFilesMappingByItemId,
        managedServers: managedServers,
        projectId: projectId,
        effectiveVarsByItemId: effectiveVarsByItemId,
        pythonPath: pythonPath,
      );

      await logSystem('create bundle.zip');
      final bundle = await _zipStage(
        stage: stagePrepared.stage,
        runArtifacts: pp.runArtifactsFor(runId),
        remoteRunDir: stagePrepared.remoteRunDir,
      );

      await _copyBundleToSnapshot(bundle.bundleZip, snapDir);
      snap['bundle_size'] = await bundle.bundleZip.length();
      snap['status'] = 'ready';
      await _writeSnapshot(snapFile, snap);

      final zipPrepared = _PreparedBundleAndRun(
        run: run,
        bundleZip: bundle.bundleZip,
        remoteRunDir: bundle.remoteRunDir,
        aborted: false,
      );

      final hasAnyRemote = orderedTasks.any((t) => t.isAnsiblePlaybook);
      if (!hasAnyRemote) {
        await logSystem('no remote tasks; mark run success');
        run = run.copyWith(systemStatus: TaskExecStatus.success);
        run = run.copyWith(
          status: RunStatus.ended,
          result: RunResult.success,
          endedAt: DateTime.now(),
          bizStatus: const BizStatus(
            status: BizStatusValue.unknown,
            message: '',
          ),
        );
        await runsStore.write(run);
        snap['status'] = 'complete';
        await _writeSnapshot(snapFile, snap);
        return;
      }

      final endpoint = SshEndpoint(
        host: controlServer.ip,
        port: controlServer.port,
        username: controlServer.username,
        password: controlServer.password,
      );

      await ssh.withConnection(endpoint, (conn) async {
        await logSystem('connect control node');
        final runtime = await ControlNodeBootstrapper(
          conn: conn,
          endpoint: endpoint,
          logger: logger,
          assets: OfflineAssets.locate(),
          controlOsHint: controlServer.controlOsHint,
          allowUnsupportedOsAutoInstall: allowUnsupportedControlOsAutoInstall,
        ).ensureReady();

        await logSystem('check ansible-playbook');
        await _requireRemoteOk(
          conn,
          '${_dq(runtime.ansiblePlaybook)} --version',
          title: '控制端缺少 ansible-playbook',
        );
        await logSystem('check /tmp writable');
        await _requireRemoteOk(
          conn,
          'bash -lc "mkdir -p /tmp/simple_deploy && echo ok > /tmp/simple_deploy/.sd_write_test && test -s /tmp/simple_deploy/.sd_write_test && rm -f /tmp/simple_deploy/.sd_write_test"',
          title: '控制端 /tmp 不可写，无法创建运行目录',
        );

        await logSystem('create remote run dir');
        await _requireRemoteOk(
          conn,
          'mkdir -p ${_dq(zipPrepared.remoteRunDir)}',
          title: '创建控制端运行目录失败',
        );
        await logSystem('upload bundle.zip');
        await _uploadFileWithVerify(
          conn,
          local: zipPrepared.bundleZip!,
          remote: '${zipPrepared.remoteRunDir}/bundle.zip',
          title: '上传 bundle.zip 失败',
          pp: pp,
          runId: runId,
          progressLabel: '传输文件',
        );
        await logSystem('unzip bundle.zip');
        await _requireRemoteOk(
          conn,
          'bash -lc "cd \\"${_bashEscape(zipPrepared.remoteRunDir)}\\" && if command -v unzip >/dev/null 2>&1; then unzip -o bundle.zip >/dev/null; else \\"${_bashEscape(runtime.pythonBin)}\\" -c \'import zipfile; zipfile.ZipFile("bundle.zip").extractall(".")\'; fi"',
          title: '控制端解包失败',
        );
        await logSystem('init remote logs/results');
        await _requireRemoteOk(
          conn,
          'cd ${_dq(zipPrepared.remoteRunDir)} && mkdir -p logs results',
          title: '控制端初始化目录失败',
        );

        run = run.copyWith(systemStatus: TaskExecStatus.success);
        await runsStore.write(run);
        snap['status'] = 'uploaded';
        await _writeSnapshot(snapFile, snap);

        for (var i = 0; i < orderedTasks.length; i++) {
          final task = orderedTasks[i];
          if (!task.isAnsiblePlaybook) {
            continue;
          }
          final playbook = _firstWhereOrNull(
            allPlaybooks,
            (p) => p.id == task.playbookId,
          );
          if (playbook == null) {
            throw AppException(
              code: AppErrorCode.unknown,
              title: 'Playbook 未找到',
              message: '任务 ${task.name} 绑定的 playbookId 不存在。',
              suggestion: '编辑任务并重新绑定 Playbook。',
            );
          }

          run = _setTaskResult(
            run,
            taskIndex: i,
            result: run.taskResults[i].copyWith(status: TaskExecStatus.running),
          );
          await runsStore.write(run);

          final localLog = pp.taskLogFile(runId, i);
          await localLog.parent.create(recursive: true);
          final sink = localLog.openWrite(mode: FileMode.writeOnlyAppend);
          final logQueue = StreamController<String>();
          Future<void> writer() async {
            var buffered = 0;
            await for (final chunk in logQueue.stream) {
              sink.write(chunk);
              buffered += chunk.length;
              if (buffered >= 4096) {
                buffered = 0;
                await sink.flush();
              }
            }
          }

          final writerFuture = writer();
          final logSanitizer = _LogSanitizer();
          var logClosed = false;
          Future<void> closeLog() async {
            if (logClosed) return;
            logClosed = true;
            await logQueue.close();
            await writerFuture;
            await sink.flush();
            await sink.close();
          }

          void pushLog(String chunk) {
            if (logQueue.isClosed) return;
            final sanitized = logSanitizer.process(chunk);
            if (sanitized.isEmpty) return;
            try {
              logQueue.add(sanitized);
            } on StateError {
              // Ignore late logs after close.
            }
          }

          try {
            final remotePlaybookPath = p.posix.normalize(playbook.relativePath);
            final remoteCmd = _taskCommand(
              runDir: zipPrepared.remoteRunDir,
              playbookPath: remotePlaybookPath,
              taskIndex: i,
              ansiblePlaybook: runtime.ansiblePlaybook,
            );
            logger.info(
              'run.task.start',
              data: {'run_id': runId, 'task_id': task.id, 'index': i},
            );

            final exit = await conn.execStream(
              remoteCmd,
              onStdout: pushLog,
              onStderr: pushLog,
            );
            final tail = logSanitizer.flush();
            if (tail.isNotEmpty) {
              pushLog(tail);
            }
            await closeLog();

            final recap = await _parseAnsibleRecapFromLog(localLog);
            if (recap != null) {
              run = run.copyWith(
                ansibleSummary: _mergeAnsibleSummary(
                  run.ansibleSummary,
                  taskIndex: i,
                  recap: recap,
                ),
              );
              await runsStore.write(run);
            }

            final recapFailed = recap?.hasFailure ?? false;
            final effectiveExit = exit == 0 && recapFailed ? 2 : exit;

            if (effectiveExit == 0) {
              run = _setTaskResult(
                run,
                taskIndex: i,
                result: run.taskResults[i].copyWith(
                  status: TaskExecStatus.success,
                  exitCode: 0,
                ),
              );
              await runsStore.write(run);
              continue;
            } else {
              final recapInfo = recapFailed
                  ? 'recap failed=${recap?.totalFailed ?? 0} unreachable=${recap?.totalUnreachable ?? 0}'
                  : null;
              final errMsg = exit == 0 && recapFailed
                  ? 'ansible-playbook recap failed ($recapInfo)'
                  : 'ansible-playbook exit=$exit';
              run = _setTaskResult(
                run,
                taskIndex: i,
                result: run.taskResults[i].copyWith(
                  status: TaskExecStatus.failed,
                  exitCode: effectiveExit,
                  error: errMsg,
                ),
              );
              run = run.copyWith(
                status: RunStatus.ended,
                result: RunResult.failed,
                endedAt: DateTime.now(),
                errorSummary: recapFailed && exit == 0
                    ? '任务失败：${task.name} (${recapInfo ?? "recap failed"})'
                    : '任务失败：${task.name} (exit=$exit)',
              );
              run = _markPendingTasksBlocked(run);
              await runsStore.write(run);
              snap['status'] = 'failed';
              snap['error'] = errMsg;
              await _writeSnapshot(snapFile, snap);
              return;
            }
          } finally {
            await closeLog();
          }
        }

        BizStatus? biz;
        final bizText = await conn.readFileOrNull(
          '${zipPrepared.remoteRunDir}/results/biz_status.json',
        );
        if (bizText != null && bizText.trim().isNotEmpty) {
          try {
            final raw = jsonDecode(bizText);
            if (raw is Map) {
              biz = BizStatus.fromJson(raw.cast<String, Object?>());
            }
          } on Object {
            biz = const BizStatus(
              status: BizStatusValue.unknown,
              message: 'biz_status.json 解析失败',
            );
          }
        } else {
          biz = const BizStatus(status: BizStatusValue.unknown, message: '');
        }

        run = run.copyWith(
          status: RunStatus.ended,
          result: RunResult.success,
          endedAt: DateTime.now(),
          bizStatus: biz,
        );
        await runsStore.write(run);
        snap['status'] = 'complete';
        await _writeSnapshot(snapFile, snap);
        await logSystem('run completed');
      });
    } on AppException catch (e) {
      logger.error(
        'run.failed',
        data: {
          'project_id': projectId,
          'batch_id': batch.id,
          'run_id': runId,
          'error': e.toString(),
        },
      );
      final shouldFailSystem = run.systemStatus == TaskExecStatus.running;
      run = run.copyWith(
        status: RunStatus.ended,
        result: RunResult.failed,
        endedAt: DateTime.now(),
        systemStatus: shouldFailSystem
            ? TaskExecStatus.failed
            : run.systemStatus,
        systemError: shouldFailSystem
            ? '${e.title}: ${e.message}'
            : run.systemError,
        errorSummary: '${e.title}: ${e.message}',
      );
      run = _markPendingTasksBlocked(run);
      await runsStore.write(run);
      if (snapshot != null && snapshotFile != null) {
        snapshot['status'] = 'failed';
        snapshot['error'] = '${e.title}: ${e.message}';
        await _writeSnapshot(snapshotFile, snapshot);
      }
      await logSystem('run failed: ${e.title}: ${e.message}');
      rethrow;
    } on Object catch (e) {
      logger.error(
        'run.failed.unknown',
        data: {
          'project_id': projectId,
          'batch_id': batch.id,
          'run_id': runId,
          'error': e.toString(),
        },
      );
      final shouldFailSystem = run.systemStatus == TaskExecStatus.running;
      run = run.copyWith(
        status: RunStatus.ended,
        result: RunResult.failed,
        endedAt: DateTime.now(),
        systemStatus: shouldFailSystem
            ? TaskExecStatus.failed
            : run.systemStatus,
        systemError: shouldFailSystem ? e.toString() : run.systemError,
        errorSummary: e.toString(),
      );
      run = _markPendingTasksBlocked(run);
      await runsStore.write(run);
      if (snapshot != null && snapshotFile != null) {
        snapshot['status'] = 'failed';
        snapshot['error'] = e.toString();
        await _writeSnapshot(snapshotFile, snapshot);
      }
      await logSystem('run failed: $e');
      throw AppException(
        code: AppErrorCode.unknown,
        title: '运行失败',
        message: '执行过程中发生未知错误。',
        suggestion: '查看 Run 日志并检查控制端环境。',
        cause: e,
      );
    } finally {
      final endedBatch =
          (await batchesStore.getById(
            batch.id,
          ))?.copyWith(status: BatchStatus.ended, updatedAt: DateTime.now()) ??
          updatedBatch.copyWith(
            status: BatchStatus.ended,
            updatedAt: DateTime.now(),
          );
      await batchesStore.upsert(endedBatch);
      await BatchLock.release(pp.batchLockFile(batch.id));
      logger.info(
        'run.lock.released',
        data: {'project_id': projectId, 'batch_id': batch.id, 'run_id': runId},
      );
    }
  }

  Run _setTaskResult(
    Run run, {
    required int taskIndex,
    required TaskRunResult result,
  }) {
    final list = List<TaskRunResult>.from(run.taskResults);
    list[taskIndex] = result;
    return run.copyWith(taskResults: list);
  }

  void _assertTaskOrderOrThrow(List<Task> orderedTasks) {
    // local_script tasks are designed as "pre-steps": they can modify bundle
    // contents before upload. To keep semantics clear, disallow local_script
    // appearing after any ansible_playbook task.
    var seenRemote = false;
    for (final t in orderedTasks) {
      if (t.isAnsiblePlaybook) seenRemote = true;
      if (seenRemote && t.isLocalScript) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: '任务顺序不支持',
          message: '脚本任务只能放在 Ansible Playbook 任务之前（作为前置步骤）。',
          suggestion: '请在批次中调整任务顺序：把脚本任务拖到最前面。',
        );
      }
    }
  }

  List<_BatchTaskEntry> _resolveOrderedEntries(
    Batch batch,
    List<Task> allTasks,
  ) {
    final items = batch.orderedTaskItems();
    if (items.isEmpty) return const [];
    final taskById = {for (final t in allTasks) t.id: t};
    final entries = <_BatchTaskEntry>[];
    for (final item in items) {
      final task = taskById[item.taskId];
      if (task == null) continue;
      if (!item.enabled) continue;
      entries.add(_BatchTaskEntry(item: item, task: task));
    }
    return entries;
  }

  Map<String, Map<String, String>> _buildEffectiveVarsByItemId(
    List<_BatchTaskEntry> entries,
    Map<String, Map<String, String>> inputVars, {
    required String pythonPath,
  }) {
    final out = <String, Map<String, String>>{};
    for (final entry in entries) {
      final t = entry.task;
      final defs = t.variables;
      if (defs.isEmpty) {
        final py = pythonPath.trim().isEmpty ? '/usr/bin/python3' : pythonPath;
        out[entry.item.id] = {'python': py};
        continue;
      }
      final map = <String, String>{
        for (final d in defs) d.name: d.defaultValue,
      };
      final provided =
          inputVars[entry.item.id] ??
          inputVars[t.id] ??
          const <String, String>{};

      // Disallow unknown vars to catch copy/paste mistakes.
      final allowed = defs.map((d) => d.name).toSet()..add('python');
      for (final k in provided.keys) {
        if (!allowed.contains(k)) {
          throw AppException(
            code: AppErrorCode.validation,
            title: '变量不合法',
            message: '任务 ${t.name} 提供了未知变量：$k',
            suggestion: '请重新打开“选择输入”对话框并重新填写变量。',
          );
        }
      }
      map.addAll(provided);

      final py = pythonPath.trim().isEmpty ? '/usr/bin/python3' : pythonPath;
      map['python'] = py;

      for (final d in defs) {
        if (!d.required) continue;
        final v = (map[d.name] ?? '').trim();
        if (v.isEmpty) {
          throw AppException(
            code: AppErrorCode.validation,
            title: '缺少必填变量',
            message: '任务 ${t.name} 的变量 ${d.name} 为必填，但未填写。',
            suggestion: '返回重新填写变量后再执行。',
          );
        }
      }
      out[entry.item.id] = map;
    }
    return out;
  }

  Future<_PreparedStage> _prepareStage({
    required ProjectPaths pp,
    required String runId,
    required List<_BatchTaskEntry> entries,
    required List<PlaybookMeta> playbooks,
    required Map<String, Map<String, List<String>>> remoteFilesMappingByItemId,
    required List<Server> managedServers,
    required String projectId,
    required Map<String, Map<String, String>> effectiveVarsByItemId,
    required String pythonPath,
  }) async {
    final runArtifacts = pp.runArtifactsFor(runId);
    await runArtifacts.create(recursive: true);

    final stage = Directory(p.join(runArtifacts.path, 'bundle_src'));
    if (await stage.exists()) {
      await stage.delete(recursive: true);
    }
    await stage.create(recursive: true);

    final filesDir = Directory(p.join(stage.path, 'files'));
    await filesDir.create(recursive: true);

    // Copy staged user inputs into bundle under files/**.
    for (final entry in entries) {
      final mapping = remoteFilesMappingByItemId[entry.item.id];
      if (mapping == null) continue;
      for (final slotEntry in mapping.entries) {
        for (final remoteRel in slotEntry.value) {
          if (!remoteRel.startsWith('files/')) {
            // control_path bindings point to pre-existing control-node paths.
            // They are not staged into the bundle.
            continue;
          }
          final artifactRel = remoteRel.substring('files/'.length);
          final src = File(p.join(runArtifacts.path, artifactRel));
          if (!await src.exists()) {
            throw AppException(
              code: AppErrorCode.storageIo,
              title: '运行输入文件丢失',
              message: '未找到已落盘的输入文件：$artifactRel',
              suggestion: '重新执行并重新选择文件。',
            );
          }
          final dst = File(p.join(stage.path, remoteRel));
          await dst.parent.create(recursive: true);
          await src.copy(dst.path);
        }
      }
    }

    // Copy playbooks directory to stage (so imported task files under
    // playbooks/** are also available on the control node).
    if (await pp.playbooksDir.exists()) {
      final dstDir = Directory(p.join(stage.path, 'playbooks'));
      await _copyDirectory(pp.playbooksDir, dstDir);
    }
    // Ensure referenced playbook entry files exist in bundle.
    for (final entry in entries.where((e) => e.task.isAnsiblePlaybook)) {
      final pbId = entry.task.playbookId;
      if (pbId == null) continue;
      final meta = _firstWhereOrNull(playbooks, (p) => p.id == pbId);
      if (meta == null) continue;
      final dst = File(p.join(stage.path, meta.relativePath));
      if (!await dst.exists()) {
        await dst.parent.create(recursive: true);
        await dst.writeAsString('---\n# missing playbook file\n', flush: true);
      }
    }

    final inventory = _buildInventory(managedServers, pythonPath);
    await File(
      p.join(stage.path, 'inventory.ini'),
    ).writeAsString('$inventory\n', flush: true);

    final remoteRunDir = '/tmp/simple_deploy/$projectId/$runId';
    final filesByTaskId = <String, Map<String, List<String>>>{};
    for (final entry in entries) {
      final mapping = remoteFilesMappingByItemId[entry.item.id];
      if (mapping == null) continue;
      filesByTaskId[entry.task.id] = mapping;
    }
    final common = <String, Object?>{
      'run_id': runId,
      'run_dir': remoteRunDir,
      'files': filesByTaskId,
      'files_by_item': remoteFilesMappingByItemId,
      'python': pythonPath,
    };
    await File(p.join(stage.path, 'vars.json')).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(common)}\n',
      flush: true,
    );

    // Per-task vars: vars_task_<index>.json
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final t = entry.task;
      final vars = <String, Object?>{
        ...common,
        'task': <String, Object?>{
          'id': t.id,
          'index': i,
          'name': t.name,
          'type': t.type,
          'item_id': entry.item.id,
          'item_name': entry.item.name,
        },
        'task_item': <String, Object?>{
          'id': entry.item.id,
          'name': entry.item.name,
          'task_id': entry.item.taskId,
          'index': i,
        },
        'task_files':
            remoteFilesMappingByItemId[entry.item.id] ??
            const <String, List<String>>{},
      };
      final eff = effectiveVarsByItemId[entry.item.id];
      if (eff != null) {
        for (final e in eff.entries) {
          vars[e.key] = e.value;
        }
      }
      await File(p.join(stage.path, 'vars_task_$i.json')).writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(vars)}\n',
        flush: true,
      );
    }

    return _PreparedStage(stage: stage, remoteRunDir: remoteRunDir);
  }

  Future<_PreparedBundle> _zipStage({
    required Directory stage,
    required Directory runArtifacts,
    required String remoteRunDir,
  }) async {
    final zip = File(p.join(runArtifacts.path, 'bundle.zip'));
    if (await zip.exists()) {
      await zip.delete();
    }
    final encoder = ZipFileEncoder();
    encoder.create(zip.path);
    await encoder.addDirectory(stage, includeDirName: false);
    await encoder.close();
    final zipSize = await zip.length();
    // An empty zip is exactly 22 bytes (end of central directory record only).
    if (zipSize <= 22) {
      final stageEntries = stage
          .listSync(recursive: true, followLinks: true)
          .length;
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '生成 bundle.zip 失败',
        message:
            'bundle.zip 为空或异常：size=$zipSize stage_entries=$stageEntries stage=${stage.path}',
        suggestion: '检查本机磁盘空间/权限，并重试执行。',
      );
    }
    return _PreparedBundle(bundleZip: zip, remoteRunDir: remoteRunDir);
  }

  Future<_PreparedLocalRun> _runLocalScripts({
    required ProjectPaths pp,
    required String runId,
    required List<_BatchTaskEntry> entries,
    required Directory stage,
    required String remoteRunDir,
    required Map<String, Map<String, String>> effectiveVarsByItemId,
    required Run run,
    required RunsStore runsStore,
  }) async {
    final runArtifacts = pp.runArtifactsFor(runId);
    await runArtifacts.create(recursive: true);

    // Execute local_script tasks (pre steps).
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final task = entry.task;
      if (!task.isLocalScript) continue;

      run = _setTaskResult(
        run,
        taskIndex: i,
        result: run.taskResults[i].copyWith(status: TaskExecStatus.running),
      );
      await runsStore.write(run);

      final localLog = pp.taskLogFile(runId, i);
      await localLog.parent.create(recursive: true);
      final sink = localLog.openWrite(mode: FileMode.writeOnlyAppend);
      try {
        final script = task.script;
        if (script == null) {
          sink.writeln('[local_script] missing script');
          run = _setTaskResult(
            run,
            taskIndex: i,
            result: run.taskResults[i].copyWith(
              status: TaskExecStatus.failed,
              exitCode: 127,
              error: 'missing script',
            ),
          );
          run = run.copyWith(
            status: RunStatus.ended,
            result: RunResult.failed,
            endedAt: DateTime.now(),
            errorSummary: '脚本任务失败：${task.name} (missing script)',
          );
          await runsStore.write(run);
          return _PreparedLocalRun(run: run, aborted: true);
        }

        var shell = script.shell.trim().isEmpty
            ? (Platform.isWindows ? 'bat' : 'bash')
            : script.shell.trim();
        if (shell == 'sh') shell = 'bash';
        final allowed = Platform.isWindows ? 'bat' : 'bash';
        if (shell != allowed) {
          sink.writeln('[local_script] unsupported shell=$shell');
          run = _setTaskResult(
            run,
            taskIndex: i,
            result: run.taskResults[i].copyWith(
              status: TaskExecStatus.failed,
              exitCode: 127,
              error: 'unsupported shell=$shell',
            ),
          );
          run = run.copyWith(
            status: RunStatus.ended,
            result: RunResult.failed,
            endedAt: DateTime.now(),
            errorSummary:
                '脚本任务失败：${task.name} (unsupported shell, expect $allowed)',
          );
          await runsStore.write(run);
          return _PreparedLocalRun(run: run, aborted: true);
        }

        final scriptsDir = Directory(
          p.join(runArtifacts.path, 'local_scripts'),
        );
        await scriptsDir.create(recursive: true);
        final scriptFile = File(p.join(scriptsDir.path, 'task_$i.$shell'));
        await scriptFile.writeAsString(
          script.content.endsWith('\n')
              ? script.content
              : '${script.content}\n',
          flush: true,
        );

        sink.writeln(
          '[local_script] shell=$shell task=${task.id.substring(0, 8)} item=${entry.item.id.substring(0, 8)} name=${task.name}',
        );
        sink.writeln('[local_script] cwd=${stage.path}');
        sink.writeln(
          '[local_script] vars_file=${p.join(stage.path, "vars_task_$i.json")}',
        );

        final env = Map<String, String>.from(Platform.environment);
        env['SD_RUN_ID'] = runId;
        env['SD_PROJECT_ID'] = run.projectId;
        env['SD_REMOTE_RUN_DIR'] = remoteRunDir;
        env['SD_STAGE_DIR'] = stage.path;
        env['SD_TASK_ID'] = task.id;
        env['SD_TASK_ITEM_ID'] = entry.item.id;
        env['SD_TASK_INDEX'] = '$i';
        env['SD_TASK_NAME'] = entry.item.name.trim().isEmpty
            ? task.name
            : entry.item.name;
        env['SD_VARS_JSON'] = p.join(stage.path, 'vars.json');
        env['SD_TASK_VARS_JSON'] = p.join(stage.path, 'vars_task_$i.json');
        final eff =
            effectiveVarsByItemId[entry.item.id] ?? const <String, String>{};
        for (final e in eff.entries) {
          env['SD_${e.key}'] = e.value;
          env['SD_${e.key.toUpperCase()}'] = e.value;
        }

        Process proc;
        try {
          if (shell == 'bat') {
            proc = await Process.start(
              'cmd',
              ['/c', scriptFile.path],
              workingDirectory: stage.path,
              environment: env,
              runInShell: false,
            );
          } else {
            proc = await Process.start(
              shell,
              [scriptFile.path],
              workingDirectory: stage.path,
              environment: env,
              runInShell: false,
            );
          }
        } on Object catch (e) {
          sink.writeln('[local_script] start failed: $e');
          run = _setTaskResult(
            run,
            taskIndex: i,
            result: run.taskResults[i].copyWith(
              status: TaskExecStatus.failed,
              exitCode: 127,
              error: 'local_script start failed',
            ),
          );
          run = run.copyWith(
            status: RunStatus.ended,
            result: RunResult.failed,
            endedAt: DateTime.now(),
            errorSummary: '脚本任务失败：${task.name} (无法启动解释器)',
          );
          await runsStore.write(run);
          return _PreparedLocalRun(run: run, aborted: true);
        }
        proc.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(sink.write);
        proc.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(sink.write);
        final exit = await proc.exitCode;

        if (exit == 0) {
          run = _setTaskResult(
            run,
            taskIndex: i,
            result: run.taskResults[i].copyWith(
              status: TaskExecStatus.success,
              exitCode: 0,
            ),
          );
          await runsStore.write(run);
          continue;
        } else {
          run = _setTaskResult(
            run,
            taskIndex: i,
            result: run.taskResults[i].copyWith(
              status: TaskExecStatus.failed,
              exitCode: exit,
              error: 'local_script exit=$exit',
            ),
          );
          run = run.copyWith(
            status: RunStatus.ended,
            result: RunResult.failed,
            endedAt: DateTime.now(),
            errorSummary: '脚本任务失败：${task.name} (exit=$exit)',
          );
          await runsStore.write(run);
          return _PreparedLocalRun(run: run, aborted: true);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
    }

    return _PreparedLocalRun(run: run, aborted: false);
  }

  Future<void> _copyDirectory(Directory src, Directory dst) async {
    if (!await src.exists()) return;
    await dst.create(recursive: true);
    await for (final entity in src.list(recursive: true, followLinks: false)) {
      final rel = p.relative(entity.path, from: src.path);
      final to = p.join(dst.path, rel);
      if (entity is Directory) {
        await Directory(to).create(recursive: true);
      } else if (entity is File) {
        await File(to).parent.create(recursive: true);
        await entity.copy(to);
      }
    }
  }

  Future<_PreparedFileInputs> _persistFileInputsToArtifacts({
    required ProjectPaths pp,
    required String runId,
    required List<_BatchTaskEntry> orderedEntries,
    required Map<String, Map<String, List<FileBinding>>> fileInputs,
    required Map<String, Map<String, String>> effectiveVarsByItemId,
  }) async {
    final runArtifacts = pp.runArtifactsFor(runId);
    await runArtifacts.create(recursive: true);

    final remoteFilesMappingByItemId = <String, Map<String, List<String>>>{};
    final entryByItemId = <String, _BatchTaskEntry>{
      for (final entry in orderedEntries) entry.item.id: entry,
    };
    final taskById = <String, Task>{
      for (final entry in orderedEntries) entry.task.id: entry.task,
    };
    final varsByItemId = effectiveVarsByItemId;
    final taskIndexByItemId = <String, int>{
      for (var i = 0; i < orderedEntries.length; i++)
        orderedEntries[i].item.id: i,
    };
    final taskIndexByTaskId = <String, int>{};
    final duplicateTaskIds = <String>{};
    for (var i = 0; i < orderedEntries.length; i++) {
      final taskId = orderedEntries[i].task.id;
      if (taskIndexByTaskId.containsKey(taskId)) {
        duplicateTaskIds.add(taskId);
      } else {
        taskIndexByTaskId[taskId] = i;
      }
    }
    for (final dup in duplicateTaskIds) {
      taskIndexByTaskId.remove(dup);
    }

    for (var taskIndex = 0; taskIndex < orderedEntries.length; taskIndex++) {
      final entry = orderedEntries[taskIndex];
      final task = entry.task;
      final taskInputs = fileInputs[entry.item.id] ?? fileInputs[task.id];
      if (taskInputs == null) {
        // Allow no inputs only if the task doesn't require any file slots.
        final requiredSlots = task.fileSlots.where((s) => s.required).toList();
        if (requiredSlots.isNotEmpty) {
          throw AppException(
            code: AppErrorCode.validation,
            title: '缺少必选文件',
            message: '任务 ${task.name} 存在必选文件槽位，但未提供任何文件输入。',
            suggestion: '返回重新选择文件后再执行。',
          );
        }
        continue;
      }

      for (final slot in task.fileSlots) {
        final list = taskInputs[slot.name] ?? const <FileBinding>[];
        if (slot.required && list.isEmpty) {
          throw AppException(
            code: AppErrorCode.validation,
            title: '缺少必选文件',
            message: '任务 ${task.name} 的槽位 ${slot.name} 为必选，但未选择文件。',
            suggestion: '返回重新选择文件后再执行。',
          );
        }
        if (!slot.multiple && list.length > 1) {
          throw AppException(
            code: AppErrorCode.validation,
            title: '文件选择数量不合法',
            message: '任务 ${task.name} 的槽位 ${slot.name} 仅允许选择 1 个文件。',
            suggestion: '返回重新选择文件后再执行。',
          );
        }
      }

      for (final slotEntry in taskInputs.entries) {
        final slotName = slotEntry.key;
        final selected = slotEntry.value;
        if (selected.isEmpty) continue;

        if (slotName.contains('/') ||
            slotName.contains('\\') ||
            slotName.contains('..')) {
          throw AppException(
            code: AppErrorCode.validation,
            title: '槽位名不合法',
            message: '槽位名包含非法字符：$slotName',
            suggestion: '编辑任务并使用仅包含字母/数字/下划线的槽位名。',
          );
        }

        final dstDir = Directory(
          p.join(runArtifacts.path, 'task_$taskIndex', slotName),
        );
        await dstDir.create(recursive: true);

        for (final binding in selected) {
          var rawPath = binding.path.trim();
          if (binding.isLocalOutput) {
            final sourceId = binding.sourceTaskId;
            final sourceOutput = binding.sourceOutput;
            Map<String, String>? sourceVars;
            if (sourceId != null) {
              var sourceTask = taskById[sourceId];
              var sourceIndex = taskIndexByTaskId[sourceId];
              final sourceEntry = entryByItemId[sourceId];
              if (sourceEntry != null) {
                sourceTask = sourceEntry.task;
                sourceIndex = taskIndexByItemId[sourceEntry.item.id];
                sourceVars = varsByItemId[sourceEntry.item.id];
              } else if (sourceIndex != null) {
                final sourceItemId = orderedEntries[sourceIndex].item.id;
                sourceVars = varsByItemId[sourceItemId];
              } else if (sourceIndex == null) {
                throw AppException(
                  code: AppErrorCode.validation,
                  title: '脚本产物来源不唯一',
                  message: '脚本产物来源无法定位到唯一任务实例。',
                  suggestion: '请重新选择脚本产物来源。',
                );
              }
              if (sourceTask == null || !sourceTask.isLocalScript) {
                throw AppException(
                  code: AppErrorCode.validation,
                  title: '脚本产物来源不合法',
                  message: '未找到对应的脚本任务：',
                  suggestion: '请重新选择脚本产物后再执行。',
                );
              }
              if ((sourceIndex ?? -1) >= taskIndex) {
                throw AppException(
                  code: AppErrorCode.validation,
                  title: '脚本产物顺序不合法',
                  message: '脚本产物必须来自当前任务之前的脚本任务。',
                  suggestion: '调整任务顺序后重试。',
                );
              }
              if (sourceOutput != null) {
                final out = _firstWhereOrNull(
                  sourceTask.outputs,
                  (o) => o.name == sourceOutput,
                );
                final derived = out == null
                    ? ''
                    : _expandPathTemplate(
                        out.path.trim(),
                        sourceVars ?? const <String, String>{},
                      );
                if (derived.isNotEmpty) {
                  rawPath = derived;
                }
              }
            }
            sourceVars ??= varsByItemId[sourceId];
            final fromVar = sourceVars?['output_path']?.trim();
            if (fromVar != null && fromVar.isNotEmpty) {
              rawPath = fromVar;
            } else if (rawPath.contains(r'${')) {
              rawPath = _expandPathTemplate(
                rawPath,
                sourceVars ?? const <String, String>{},
              );
            }
          }
          if (rawPath.isEmpty) {
            if (binding.isLocalOutput) {
              throw AppException(
                code: AppErrorCode.validation,
                title: '脚本产物路径为空',
                message: '脚本产物未配置有效路径。',
                suggestion: '请检查脚本任务的产物配置。',
              );
            }
            continue;
          }

          if (binding.isControl) {
            if (!p.posix.isAbsolute(rawPath)) {
              throw AppException(
                code: AppErrorCode.validation,
                title: '控制端路径不合法',
                message: '控制端路径必须为绝对路径：$rawPath',
                suggestion: '使用以 / 开头的绝对路径。',
              );
            }
            remoteFilesMappingByItemId
                .putIfAbsent(entry.item.id, () => <String, List<String>>{})
                .putIfAbsent(slotName, () => <String>[])
                .add(rawPath);
            continue;
          }

          if (binding.isLocalOutput && !p.isAbsolute(rawPath)) {
            throw AppException(
              code: AppErrorCode.validation,
              title: '脚本产物路径不合法',
              message: '脚本产物路径必须为绝对路径：$rawPath',
              suggestion: '请检查产物配置或变量模板是否可解析为绝对路径。',
            );
          }

          if (!p.isAbsolute(rawPath)) {
            throw AppException(
              code: AppErrorCode.validation,
              title: '本地路径不合法',
              message: '本地路径必须为绝对路径：$rawPath',
              suggestion: '请填写绝对路径，或使用文件选择器。',
            );
          }

          final src = File(rawPath);
          if (!await src.exists()) {
            throw AppException(
              code: AppErrorCode.validation,
              title: '输入文件不存在',
              message: '文件路径不存在：$rawPath',
              suggestion: '重新选择文件后再执行。',
            );
          }
          if (await FileSystemEntity.type(rawPath) !=
              FileSystemEntityType.file) {
            throw AppException(
              code: AppErrorCode.validation,
              title: '输入路径不是文件',
              message: '仅支持文件路径：$rawPath',
              suggestion: '请选择单个文件后再执行。',
            );
          }

          final baseName = p.basename(rawPath);
          final uniqueName = await _pickUniqueName(dstDir, baseName);
          final dst = File(p.join(dstDir.path, uniqueName));
          await src.copy(dst.path);

          final remoteRel = p.posix.join(
            'files',
            'task_$taskIndex',
            slotName,
            uniqueName,
          );
          remoteFilesMappingByItemId
              .putIfAbsent(entry.item.id, () => <String, List<String>>{})
              .putIfAbsent(slotName, () => <String>[])
              .add(remoteRel);
        }
      }
    }

    return _PreparedFileInputs(
      remoteFilesMappingByItemId: remoteFilesMappingByItemId,
    );
  }

  Future<String> _pickUniqueName(Directory dir, String desired) async {
    final ext = p.extension(desired);
    final stem = p.basenameWithoutExtension(desired);
    var candidate = desired;
    var i = 1;
    while (await File(p.join(dir.path, candidate)).exists()) {
      candidate = '${stem}_$i$ext';
      i++;
      if (i > 9999) {
        throw const AppException(
          code: AppErrorCode.validation,
          title: '文件名冲突过多',
          message: '同一槽位下存在过多同名文件，无法自动重命名。',
          suggestion: '请减少重复文件名，或手动重命名后再选择。',
        );
      }
    }
    return candidate;
  }

  String _buildInventory(List<Server> managedServers, String pythonPath) {
    final lines = <String>['[all]'];
    for (final s in managedServers) {
      final id = s.id.replaceAll('-', '_');
      final user = s.username.isEmpty ? 'root' : s.username;
      final pyRaw = pythonPath.trim().isEmpty ? '/usr/bin/python3' : pythonPath;
      final py = _iniEscape(pyRaw);
      lines.add(
        'host_$id ansible_host=${s.ip} ansible_user=$user ansible_password=${_iniEscape(s.password)} ansible_port=${s.port} ansible_connection=paramiko ansible_python_interpreter=$py',
      );
    }
    return lines.join('\n');
  }

  static String _iniEscape(String value) {
    // inventory.ini is simple; wrap spaces.
    if (value.contains(' ') || value.contains('#') || value.contains(';')) {
      return '"${value.replaceAll('"', '\\"')}"';
    }
    return value;
  }

  static String _taskCommand({
    required String runDir,
    required String playbookPath,
    required int taskIndex,
    required String ansiblePlaybook,
  }) {
    final dir = _bashEscape(runDir);
    final pb = _bashEscape(playbookPath);
    final log = _bashEscape('logs/task_$taskIndex.log');
    final ab = _bashEscape(ansiblePlaybook);
    final vars = _bashEscape('vars_task_$taskIndex.json');
    return 'bash -lc "cd \\"$dir\\" && set -o pipefail; ANSIBLE_HOST_KEY_CHECKING=False \\"$ab\\" -i inventory.ini \\"$pb\\" --extra-vars @$vars 2>&1 | tee \\"$log\\"; exit \${PIPESTATUS[0]}"';
  }

  static String _bashEscape(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

  static String _dq(String s) => '"${_bashEscape(s)}"';

  static final RegExp _varTemplateRe = RegExp(
    r'\\$\\{([A-Za-z_][A-Za-z0-9_]*)\\}',
  );

  static String _expandPathTemplate(String input, Map<String, String> vars) {
    if (input.isEmpty) return input;
    return input.replaceAllMapped(_varTemplateRe, (m) {
      final key = m.group(1) ?? '';
      if (key.isEmpty) return m.group(0) ?? '';
      return vars[key] ??
          vars[key.toLowerCase()] ??
          vars[key.toUpperCase()] ??
          (m.group(0) ?? '');
    });
  }

  static Map<String, Object?> _mergeAnsibleSummary(
    Map<String, Object?>? existing, {
    required int taskIndex,
    required _AnsibleRecap recap,
  }) {
    final next = Map<String, Object?>.from(existing ?? const {});
    next['task_$taskIndex'] = recap.toJson();
    return next;
  }

  Future<_AnsibleRecap?> _parseAnsibleRecapFromLog(File logFile) async {
    if (!await logFile.exists()) return null;
    final tail = await _readTail(logFile, 256 * 1024);
    return _parseAnsibleRecapText(tail);
  }

  static _AnsibleRecap? _parseAnsibleRecapText(String text) {
    final lines = const LineSplitter().convert(text);
    var start = -1;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('PLAY RECAP')) {
        start = i;
      }
    }
    if (start < 0) return null;

    final hosts = <String, Map<String, int>>{};
    for (var i = start + 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (line.startsWith('PLAY ') && !line.startsWith('PLAY RECAP')) {
        break;
      }
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final host = line.substring(0, colon).trim();
      final statsPart = line.substring(colon + 1);
      final matches = RegExp(r'(\\w+)=(\\d+)').allMatches(statsPart);
      if (matches.isEmpty) continue;
      final stats = <String, int>{};
      for (final m in matches) {
        final key = m.group(1);
        final val = m.group(2);
        if (key == null || val == null) continue;
        stats[key] = int.tryParse(val) ?? 0;
      }
      if (stats.isNotEmpty) {
        hosts[host] = stats;
      }
    }
    if (hosts.isEmpty) return null;
    return _AnsibleRecap.fromHosts(hosts);
  }

  static Future<String> _readTail(File file, int maxBytes) async {
    final raf = await file.open();
    try {
      final len = await raf.length();
      final start = len > maxBytes ? len - maxBytes : 0;
      await raf.setPosition(start);
      final bytes = await raf.read(len - start);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await raf.close();
    }
  }

  static T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
    for (final x in items) {
      if (test(x)) return x;
    }
    return null;
  }

  Map<String, Object?> _snapshotServer(Server s) {
    return {
      'id': s.id,
      'name': s.name,
      'ip': s.ip,
      'port': s.port,
      'username': s.username,
      'type': s.type,
      'enabled': s.enabled,
    };
  }

  Future<void> _writeSnapshot(File file, Map<String, Object?> snapshot) async {
    await AtomicFile.writeJson(file, snapshot);
  }

  Future<Map<String, Object?>> _copySnapshotFilesFromArtifacts(
    Directory runArtifacts,
    Directory snapshotDir,
  ) async {
    final out = <String, Object?>{};
    final filesRoot = Directory(p.join(snapshotDir.path, 'files'));
    await filesRoot.create(recursive: true);
    if (!await runArtifacts.exists()) return out;
    await for (final entity in runArtifacts.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: runArtifacts.path);
      if (!rel.startsWith('task_')) continue;
      final dst = File(p.join(filesRoot.path, rel));
      await dst.parent.create(recursive: true);
      await entity.copy(dst.path);
      final stat = await dst.stat();
      out[p.posix.join('files', rel.replaceAll('\\', '/'))] = {
        'size': stat.size,
        'mtime': stat.modified.toIso8601String(),
      };
    }
    return out;
  }

  Future<void> _copyBundleToSnapshot(File bundle, Directory snapshotDir) async {
    final dst = File(p.join(snapshotDir.path, 'bundle.zip'));
    if (await dst.exists()) {
      await dst.delete();
    }
    await bundle.copy(dst.path);
  }

  Run _markPendingTasksBlocked(Run run) {
    final list = <TaskRunResult>[];
    for (final t in run.taskResults) {
      if (t.status == TaskExecStatus.waiting) {
        list.add(t.copyWith(status: TaskExecStatus.blocked));
      } else {
        list.add(t);
      }
    }
    return run.copyWith(taskResults: list);
  }

  Future<void> _requireRemoteOk(
    SshConnection conn,
    String command, {
    required String title,
  }) async {
    final r = await conn.execWithResult(command);
    if (r.exitCode != 0) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: title,
        message: 'exit=${r.exitCode}\n${r.stdout}\n${r.stderr}'.trim(),
        suggestion: '检查控制端权限/依赖，并查看控制端侧日志。',
      );
    }
  }

  Future<void> _writeUploadProgress(
    ProjectPaths pp,
    String runId,
    UploadProgress progress,
  ) async {
    try {
      await AtomicFile.writeJson(
        pp.runUploadProgressFile(runId),
        progress.toJson(),
      );
    } on Object catch (e) {
      logger.warn(
        'run.upload.progress.write_failed',
        data: {'run_id': runId, 'error': e.toString()},
      );
    }
  }

  Future<void> _uploadFileWithVerify(
    SshConnection conn, {
    required File local,
    required String remote,
    required String title,
    required ProjectPaths pp,
    required String runId,
    String? progressLabel,
  }) async {
    final localSize = await local.length();
    if (localSize <= 0) {
      throw AppException(
        code: AppErrorCode.storageIo,
        title: title,
        message: '本地文件大小异常：size=$localSize path=${local.path}',
        suggestion: '检查本机磁盘空间与文件权限后重试。',
      );
    }

    final label = progressLabel?.trim().isNotEmpty == true
        ? progressLabel!.trim()
        : p.basename(local.path);
    var lastWriteAt = DateTime.fromMillisecondsSinceEpoch(0);
    UploadProgress progress = UploadProgress(
      status: UploadProgressStatus.running,
      sent: 0,
      total: localSize,
      message: label,
      updatedAt: DateTime.now(),
    );
    await _writeUploadProgress(pp, runId, progress);

    Future<int?> readRemoteSize() async {
      final r = await conn.execWithResult(
        'bash -lc "test -f ${_dq(remote)} && wc -c < ${_dq(remote)}"',
      );
      if (r.exitCode != 0) return null;
      return int.tryParse(r.stdout.trim());
    }

    void maybeWriteProgress(UploadProgress next, {bool force = false}) {
      final now = DateTime.now();
      if (!force && now.difference(lastWriteAt).inMilliseconds < 200) {
        return;
      }
      lastWriteAt = now;
      // ignore: unawaited_futures
      unawaited(_writeUploadProgress(pp, runId, next));
    }

    try {
      for (var attempt = 1; attempt <= 2; attempt++) {
        final attemptLabel = attempt == 1 ? label : '$label (重试 $attempt/2)';
        progress = progress.copyWith(
          status: UploadProgressStatus.running,
          sent: 0,
          total: localSize,
          message: attemptLabel,
          updatedAt: DateTime.now(),
        );
        maybeWriteProgress(progress, force: true);

        await conn.uploadFile(
          local,
          remote,
          onProgress: (sent, total) {
            progress = progress.copyWith(
              sent: sent,
              total: total > 0 ? total : localSize,
              updatedAt: DateTime.now(),
            );
            maybeWriteProgress(progress);
          },
        );
        final remoteSize = await readRemoteSize();
        if (remoteSize == localSize) {
          progress = progress.copyWith(
            status: UploadProgressStatus.success,
            sent: localSize,
            total: localSize,
            updatedAt: DateTime.now(),
          );
          await _writeUploadProgress(pp, runId, progress);
          return;
        }
        logger.warn(
          'run.bundle.upload.size_mismatch',
          data: {
            'attempt': attempt,
            'local': local.path,
            'local_size': localSize,
            'remote': remote,
            'remote_size': remoteSize,
          },
        );
      }
    } on Object {
      progress = progress.copyWith(
        status: UploadProgressStatus.failed,
        message: '$label 上传失败',
        updatedAt: DateTime.now(),
      );
      await _writeUploadProgress(pp, runId, progress);
      rethrow;
    }

    final finalRemoteSize = await readRemoteSize();
    progress = progress.copyWith(
      status: UploadProgressStatus.failed,
      sent: localSize,
      total: localSize,
      message: '$label 上传失败',
      updatedAt: DateTime.now(),
    );
    await _writeUploadProgress(pp, runId, progress);
    throw AppException(
      code: AppErrorCode.storageIo,
      title: title,
      message:
          '上传后文件大小不一致：local=$localSize remote=${finalRemoteSize ?? 'unknown'} path=$remote',
      suggestion: '检查控制端磁盘空间、/tmp 可写性与网络稳定性后重试。',
    );
  }
}

class _PreparedFileInputs {
  final Map<String, Map<String, List<String>>> remoteFilesMappingByItemId;

  const _PreparedFileInputs({required this.remoteFilesMappingByItemId});
}

class _PreparedStage {
  final Directory stage;
  final String remoteRunDir;

  const _PreparedStage({required this.stage, required this.remoteRunDir});
}

class _PreparedBundleAndRun {
  final Run run;
  final File? bundleZip;
  final String remoteRunDir;
  final bool aborted;

  const _PreparedBundleAndRun({
    required this.run,
    required this.bundleZip,
    required this.remoteRunDir,
    required this.aborted,
  });
}

class _PreparedLocalRun {
  final Run run;
  final bool aborted;

  const _PreparedLocalRun({required this.run, required this.aborted});
}

class _PreparedBundle {
  final File bundleZip;
  final String remoteRunDir;

  const _PreparedBundle({required this.bundleZip, required this.remoteRunDir});
}

class _LogSanitizer {
  String _pending = '';

  String process(String chunk) {
    final combined = '$_pending$chunk';
    final parts = combined.split('\n');
    _pending = parts.removeLast();
    if (parts.isEmpty) return '';
    final out = StringBuffer();
    for (final line in parts) {
      final filtered = _filterLine(line);
      if (filtered == null) continue;
      out.writeln(filtered);
    }
    return out.toString();
  }

  String flush() {
    if (_pending.isEmpty) return '';
    final filtered = _filterLine(_pending);
    _pending = '';
    if (filtered == null) return '';
    return '$filtered\n';
  }

  String? _filterLine(String line) {
    final trimmed = line.trimRight();
    if (trimmed.isEmpty) return line;
    if (trimmed.contains('zip_data')) {
      return '[已省略 zip_data]';
    }
    if (trimmed.length > 5000 && _looksLikeBase64(trimmed)) {
      return '[已省略 base64 数据]';
    }
    return line;
  }

  bool _looksLikeBase64(String line) {
    if (line.length < 200) return false;
    final base64Re = RegExp(r'^[A-Za-z0-9+/=]+$');
    return base64Re.hasMatch(line);
  }
}

class _AnsibleRecap {
  final Map<String, Map<String, int>> hosts;
  final int totalFailed;
  final int totalUnreachable;

  const _AnsibleRecap({
    required this.hosts,
    required this.totalFailed,
    required this.totalUnreachable,
  });

  factory _AnsibleRecap.fromHosts(Map<String, Map<String, int>> hosts) {
    var failed = 0;
    var unreachable = 0;
    for (final stats in hosts.values) {
      failed += stats['failed'] ?? 0;
      unreachable += stats['unreachable'] ?? 0;
    }
    return _AnsibleRecap(
      hosts: hosts,
      totalFailed: failed,
      totalUnreachable: unreachable,
    );
  }

  bool get hasFailure => totalFailed > 0 || totalUnreachable > 0;

  Map<String, Object?> toJson() {
    return {
      'failed': totalFailed,
      'unreachable': totalUnreachable,
      'hosts': hosts.map(
        (host, stats) => MapEntry(host, stats.map((k, v) => MapEntry(k, v))),
      ),
    };
  }
}
