import 'dart:io';

import 'package:path/path.dart' as p;

import 'atomic_file.dart';

class ProjectPaths {
  final Directory projectsRoot;
  final String projectId;

  const ProjectPaths({required this.projectsRoot, required this.projectId});

  Directory get projectDir => Directory(p.join(projectsRoot.path, projectId));

  File get projectFile => AtomicFile.childFile(projectDir, 'project.json');

  File get serversFile => AtomicFile.childFile(projectDir, 'servers.json');
  File get playbooksIndexFile =>
      AtomicFile.childFile(projectDir, 'playbooks.json');
  File get tasksFile => AtomicFile.childFile(projectDir, 'tasks.json');

  Directory get playbooksDir => Directory(p.join(projectDir.path, 'playbooks'));

  Directory get batchesDir => Directory(p.join(projectDir.path, 'batches'));
  Directory get runsDir => Directory(p.join(projectDir.path, 'runs'));

  Directory get runArtifactsDir =>
      Directory(p.join(projectDir.path, 'run_artifacts'));
  Directory get runLogsDir => Directory(p.join(projectDir.path, 'run_logs'));

  Directory get locksDir => Directory(p.join(projectDir.path, 'locks'));

  File batchFile(String batchId) =>
      AtomicFile.childFile(batchesDir, '$batchId.json');
  File batchLastInputsFile(String batchId) =>
      AtomicFile.childFile(batchesDir, '$batchId.last_inputs');
  File runFile(String runId) => AtomicFile.childFile(runsDir, '$runId.json');

  Directory runArtifactsFor(String runId) =>
      Directory(p.join(runArtifactsDir.path, runId));
  Directory runLogsFor(String runId) =>
      Directory(p.join(runLogsDir.path, runId));

  File taskLogFile(String runId, int taskIndex) =>
      AtomicFile.childFile(runLogsFor(runId), 'task_$taskIndex.log');
  File runUploadProgressFile(String runId) =>
      AtomicFile.childFile(runLogsFor(runId), 'upload_progress.json');

  File batchLockFile(String batchId) =>
      AtomicFile.childFile(locksDir, 'batch_$batchId.lock');

  Future<void> ensureExists() async {
    await projectDir.create(recursive: true);
    await playbooksDir.create(recursive: true);
    await batchesDir.create(recursive: true);
    await runsDir.create(recursive: true);
    await runArtifactsDir.create(recursive: true);
    await runLogsDir.create(recursive: true);
    await locksDir.create(recursive: true);
  }
}
