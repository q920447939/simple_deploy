import 'dart:io';

import 'package:uuid/uuid.dart';

import '../storage/app_paths.dart';
import '../storage/atomic_file.dart';
import '../storage/batches_store.dart';
import '../storage/playbooks_store.dart';
import '../storage/projects_store.dart';
import '../storage/project_paths.dart';
import '../storage/runs_store.dart';
import '../storage/servers_store.dart';
import '../storage/tasks_store.dart';
import 'core/app_logger.dart';
import 'run_engine/run_engine.dart';
import 'ssh/ssh_service.dart';

class AppServices {
  static AppServices? _instance;

  final AppPaths paths;
  final AppLogger logger;
  final ProjectsStore projectsStore;
  final Uuid uuid;
  final SshService sshService;
  final RunEngine runEngine;

  AppServices._({
    required this.paths,
    required this.logger,
    required this.projectsStore,
    required this.uuid,
    required this.sshService,
    required this.runEngine,
  });

  static AppServices get I {
    final instance = _instance;
    if (instance == null) {
      throw StateError('AppServices not initialized.');
    }
    return instance;
  }

  static Future<void> init() async {
    if (_instance != null) {
      return;
    }

    final paths = await AppPaths.resolve(appName: 'simple_deploy');
    await paths.ensureExists();

    final logger = await AppLogger.create(
      logsDir: paths.appLogsDir,
      filePrefix: 'simple_deploy',
    );

    logger.info(
      'app.start',
      data: {'pid': pid, 'platform': Platform.operatingSystem},
    );

    await AtomicFile.writeJson(paths.appStateFile, {
      'last_launch_at': DateTime.now().toIso8601String(),
    });

    final projectsStore = ProjectsStore(
      file: paths.projectsIndexFile,
      projectsDir: paths.projectsDir,
      logger: logger,
    );

    final sshService = SshService();
    final runEngine = RunEngine(
      ssh: sshService,
      logger: logger,
      uuid: const Uuid(),
      projectsRoot: paths.projectsDir,
    );

    _instance = AppServices._(
      paths: paths,
      logger: logger,
      projectsStore: projectsStore,
      uuid: const Uuid(),
      sshService: sshService,
      runEngine: runEngine,
    );
  }

  ProjectPaths projectPaths(String projectId) =>
      ProjectPaths(projectsRoot: paths.projectsDir, projectId: projectId);

  ServersStore serversStore(String projectId) =>
      ServersStore(paths: projectPaths(projectId), logger: logger);

  PlaybooksStore playbooksStore(String projectId) =>
      PlaybooksStore(paths: projectPaths(projectId), logger: logger);

  TasksStore tasksStore(String projectId) =>
      TasksStore(paths: projectPaths(projectId), logger: logger);

  BatchesStore batchesStore(String projectId) =>
      BatchesStore(paths: projectPaths(projectId), logger: logger);

  RunsStore runsStore(String projectId) =>
      RunsStore(paths: projectPaths(projectId), logger: logger);
}
