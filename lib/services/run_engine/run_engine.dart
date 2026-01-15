import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../model/batch.dart';
import '../../model/playbook_meta.dart';
import '../../model/run.dart';
import '../../model/server.dart';
import '../../model/task.dart';
import '../../services/core/app_error.dart';
import '../../services/core/app_logger.dart';
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
    required Map<String, Map<String, List<String>>> fileInputs,
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

    final orderedTasks = batch.taskOrder
        .map((id) => _firstWhereOrNull(allTasks, (t) => t.id == id))
        .whereType<Task>()
        .toList();
    if (orderedTasks.isEmpty) {
      throw const AppException(
        code: AppErrorCode.unknown,
        title: '任务为空',
        message: '批次任务顺序为空或任务不存在。',
        suggestion: '编辑批次并选择至少 1 个任务。',
      );
    }

    final runId = uuid.v4();
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

    Run run = Run(
      id: runId,
      projectId: projectId,
      batchId: batch.id,
      startedAt: DateTime.now(),
      endedAt: null,
      status: RunStatus.running,
      result: RunResult.failed,
      taskResults: [
        for (final t in orderedTasks)
          TaskRunResult(
            taskId: t.id,
            status: TaskExecStatus.waiting,
            exitCode: null,
            fileInputs: null,
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
    );

    try {
      await batchesStore.upsert(updatedBatch);
      await runsStore.write(run);

      final preparedInputs = await _persistFileInputsToArtifacts(
        pp: pp,
        runId: runId,
        orderedTasks: orderedTasks,
        fileInputs: fileInputs,
      );

      run = run.copyWith(
        taskResults: [
          for (var i = 0; i < orderedTasks.length; i++)
            run.taskResults[i].copyWith(
              fileInputs: preparedInputs.remoteFilesMapping[orderedTasks[i].id],
            ),
        ],
      );
      await runsStore.write(run);

      final prepared = await _prepareBundle(
        pp: pp,
        runId: runId,
        tasks: orderedTasks,
        playbooks: allPlaybooks,
        remoteFilesMapping: preparedInputs.remoteFilesMapping,
        managedServers: managedServers,
        projectId: projectId,
      );

      final endpoint = SshEndpoint(
        host: controlServer.ip,
        port: controlServer.port,
        username: controlServer.username,
        password: controlServer.password,
      );

      await ssh.withConnection(endpoint, (conn) async {
        final runtime = await ControlNodeBootstrapper(
          conn: conn,
          endpoint: endpoint,
          logger: logger,
          assets: OfflineAssets.locate(),
          controlOsHint: controlServer.controlOsHint,
          allowUnsupportedOsAutoInstall: allowUnsupportedControlOsAutoInstall,
        ).ensureReady();

        await _requireRemoteOk(
          conn,
          '${_dq(runtime.ansiblePlaybook)} --version',
          title: '控制端缺少 ansible-playbook',
        );
        await _requireRemoteOk(
          conn,
          'bash -lc "mkdir -p /tmp/simple_deploy && echo ok > /tmp/simple_deploy/.sd_write_test && test -s /tmp/simple_deploy/.sd_write_test && rm -f /tmp/simple_deploy/.sd_write_test"',
          title: '控制端 /tmp 不可写，无法创建运行目录',
        );

        await _requireRemoteOk(
          conn,
          'mkdir -p ${_dq(prepared.remoteRunDir)}',
          title: '创建控制端运行目录失败',
        );
        await _uploadFileWithVerify(
          conn,
          local: prepared.bundleZip,
          remote: '${prepared.remoteRunDir}/bundle.zip',
          title: '上传 bundle.zip 失败',
        );
        await _requireRemoteOk(
          conn,
          'bash -lc "cd \\"${_bashEscape(prepared.remoteRunDir)}\\" && if command -v unzip >/dev/null 2>&1; then unzip -o bundle.zip >/dev/null; else \\"${_bashEscape(runtime.pythonBin)}\\" -c \'import zipfile; zipfile.ZipFile("bundle.zip").extractall(".")\'; fi"',
          title: '控制端解包失败',
        );
        await _requireRemoteOk(
          conn,
          'cd ${_dq(prepared.remoteRunDir)} && mkdir -p logs results',
          title: '控制端初始化目录失败',
        );

        for (var i = 0; i < orderedTasks.length; i++) {
          final task = orderedTasks[i];
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
          var buffered = 0;
          try {
            final remotePlaybookPath = p.posix.normalize(playbook.relativePath);
            final remoteCmd = _taskCommand(
              runDir: prepared.remoteRunDir,
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
              onStdout: (chunk) {
                sink.write(chunk);
                buffered += chunk.length;
                if (buffered >= 4096) {
                  buffered = 0;
                  // ignore: unawaited_futures
                  sink.flush();
                }
              },
              onStderr: (chunk) {
                sink.write(chunk);
                buffered += chunk.length;
                if (buffered >= 4096) {
                  buffered = 0;
                  // ignore: unawaited_futures
                  sink.flush();
                }
              },
            );

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
                  error: 'ansible-playbook exit=$exit',
                ),
              );
              run = run.copyWith(
                status: RunStatus.ended,
                result: RunResult.failed,
                endedAt: DateTime.now(),
                errorSummary: '任务失败：${task.name} (exit=$exit)',
              );
              await runsStore.write(run);
              return;
            }
          } finally {
            await sink.flush();
            await sink.close();
          }
        }

        BizStatus? biz;
        final bizText = await conn.readFileOrNull(
          '${prepared.remoteRunDir}/results/biz_status.json',
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
      run = run.copyWith(
        status: RunStatus.ended,
        result: RunResult.failed,
        endedAt: DateTime.now(),
        errorSummary: '${e.title}: ${e.message}',
      );
      await runsStore.write(run);
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
      run = run.copyWith(
        status: RunStatus.ended,
        result: RunResult.failed,
        endedAt: DateTime.now(),
        errorSummary: e.toString(),
      );
      await runsStore.write(run);
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

  Future<_PreparedBundle> _prepareBundle({
    required ProjectPaths pp,
    required String runId,
    required List<Task> tasks,
    required List<PlaybookMeta> playbooks,
    required Map<String, Map<String, List<String>>> remoteFilesMapping,
    required List<Server> managedServers,
    required String projectId,
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
    for (final task in tasks) {
      final mapping = remoteFilesMapping[task.id];
      if (mapping == null) continue;
      for (final entry in mapping.entries) {
        for (final remoteRel in entry.value) {
          if (!remoteRel.startsWith('files/')) {
            throw AppException(
              code: AppErrorCode.unknown,
              title: '文件映射不合法',
              message: 'remoteRel 必须以 files/ 开头：$remoteRel',
              suggestion: '请重试；如持续出现请清理项目数据后再试。',
            );
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

    // Copy needed playbooks into stage.
    for (final task in tasks) {
      final meta = _firstWhereOrNull(playbooks, (p) => p.id == task.playbookId);
      if (meta == null) {
        continue;
      }
      final src = File(p.join(pp.projectDir.path, meta.relativePath));
      final dst = File(p.join(stage.path, meta.relativePath));
      await dst.parent.create(recursive: true);
      if (await src.exists()) {
        await src.copy(dst.path);
      } else {
        await dst.writeAsString('---\n# missing playbook file\n', flush: true);
      }
    }

    final inventory = _buildInventory(managedServers);
    await File(
      p.join(stage.path, 'inventory.ini'),
    ).writeAsString('$inventory\n', flush: true);

    final remoteRunDir = '/tmp/simple_deploy/$projectId/$runId';
    final vars = <String, Object?>{
      'run_id': runId,
      'run_dir': remoteRunDir,
      'files': remoteFilesMapping,
    };
    await File(p.join(stage.path, 'vars.json')).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(vars)}\n',
      flush: true,
    );

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
      final stageEntries =
          stage.listSync(recursive: true, followLinks: true).length;
      throw AppException(
        code: AppErrorCode.storageIo,
        title: '生成 bundle.zip 失败',
        message:
            'bundle.zip 为空或异常：size=$zipSize stage_entries=$stageEntries stage=${stage.path}',
        suggestion: '检查本机磁盘空间/权限，并重试执行。',
      );
    }

    return _PreparedBundle(
      bundleZip: zip,
      remoteRunDir: remoteRunDir,
      filesMapping: remoteFilesMapping,
    );
  }

  Future<_PreparedFileInputs> _persistFileInputsToArtifacts({
    required ProjectPaths pp,
    required String runId,
    required List<Task> orderedTasks,
    required Map<String, Map<String, List<String>>> fileInputs,
  }) async {
    final runArtifacts = pp.runArtifactsFor(runId);
    await runArtifacts.create(recursive: true);

    final remoteFilesMapping = <String, Map<String, List<String>>>{};

    for (var taskIndex = 0; taskIndex < orderedTasks.length; taskIndex++) {
      final task = orderedTasks[taskIndex];
      final taskInputs = fileInputs[task.id];
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
        final list = taskInputs[slot.name] ?? const <String>[];
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

      for (final entry in taskInputs.entries) {
        final slotName = entry.key;
        final selected = entry.value;
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

        for (final localPath in selected) {
          final src = File(localPath);
          if (!await src.exists()) {
            throw AppException(
              code: AppErrorCode.validation,
              title: '输入文件不存在',
              message: '文件路径不存在：$localPath',
              suggestion: '重新选择文件后再执行。',
            );
          }
          final baseName = p.basename(localPath);
          final uniqueName = await _pickUniqueName(dstDir, baseName);
          final dst = File(p.join(dstDir.path, uniqueName));
          await src.copy(dst.path);

          final remoteRel = p.posix.join(
            'files',
            'task_$taskIndex',
            slotName,
            uniqueName,
          );
          remoteFilesMapping
              .putIfAbsent(task.id, () => <String, List<String>>{})
              .putIfAbsent(slotName, () => <String>[])
              .add(remoteRel);
        }
      }
    }

    return _PreparedFileInputs(remoteFilesMapping: remoteFilesMapping);
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

  String _buildInventory(List<Server> managedServers) {
    final lines = <String>['[all]'];
    for (final s in managedServers) {
      final id = s.id.replaceAll('-', '_');
      final user = s.username.isEmpty ? 'root' : s.username;
      lines.add(
        'host_$id ansible_host=${s.ip} ansible_user=$user ansible_password=${_iniEscape(s.password)} ansible_port=${s.port} ansible_connection=paramiko ansible_python_interpreter=/usr/bin/python3',
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
    return 'bash -lc "cd \\"$dir\\" && set -o pipefail; ANSIBLE_HOST_KEY_CHECKING=False \\"$ab\\" -i inventory.ini \\"$pb\\" --extra-vars @vars.json 2>&1 | tee \\"$log\\"; exit \${PIPESTATUS[0]}"';
  }

  static String _bashEscape(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

  static String _dq(String s) => '"${_bashEscape(s)}"';

  static T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
    for (final x in items) {
      if (test(x)) return x;
    }
    return null;
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

  Future<void> _uploadFileWithVerify(
    SshConnection conn, {
    required File local,
    required String remote,
    required String title,
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

    Future<int?> readRemoteSize() async {
      final r = await conn.execWithResult(
        'bash -lc "test -f ${_dq(remote)} && wc -c < ${_dq(remote)}"',
      );
      if (r.exitCode != 0) return null;
      return int.tryParse(r.stdout.trim());
    }

    for (var attempt = 1; attempt <= 2; attempt++) {
      await conn.uploadFile(local, remote);
      final remoteSize = await readRemoteSize();
      if (remoteSize == localSize) {
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

    final finalRemoteSize = await readRemoteSize();
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
  final Map<String, Map<String, List<String>>> remoteFilesMapping;

  const _PreparedFileInputs({required this.remoteFilesMapping});
}

class _PreparedBundle {
  final File bundleZip;
  final String remoteRunDir;
  final Map<String, Map<String, List<String>>> filesMapping;

  const _PreparedBundle({
    required this.bundleZip,
    required this.remoteRunDir,
    required this.filesMapping,
  });
}
