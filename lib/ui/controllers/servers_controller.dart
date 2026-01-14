import 'package:get/get.dart';

import '../../model/server.dart';
import '../../services/app_services.dart';
import '../../services/core/app_error.dart';
import '../../services/core/app_logger.dart';
import '../../services/ssh/ssh_service.dart';
import 'projects_controller.dart';

class ServersController extends GetxController {
  final ProjectsController projects = Get.find<ProjectsController>();

  final RxList<Server> servers = <Server>[].obs;
  final RxnString selectedId = RxnString();
  final RxString filterType = ServerType.control.obs;
  final RxnString testingId = RxnString();
  final RxnString testingMode = RxnString(); // ssh | selfcheck

  AppLogger get _logger => AppServices.I.logger;

  @override
  void onInit() {
    super.onInit();
    ever<String?>(projects.selectedId, (_) => load());
    ever<String>(filterType, (_) => selectedId.value = null);
    load();
  }

  String? get projectId => projects.selectedId.value;

  Future<void> load() async {
    final pid = projectId;
    if (pid == null) {
      servers.clear();
      selectedId.value = null;
      return;
    }
    final list = await AppServices.I.serversStore(pid).list();
    servers.assignAll(list);
    final currentSelected = selectedId.value;
    if (currentSelected == null) {
      final first = filtered.isEmpty ? null : filtered.first;
      selectedId.value = first?.id;
    } else {
      if (!servers.any((s) => s.id == currentSelected)) {
        selectedId.value = filtered.isEmpty ? null : filtered.first.id;
      }
    }
  }

  Iterable<Server> get filtered =>
      servers.where((s) => s.type == filterType.value);

  Server? get selected {
    final id = selectedId.value;
    if (id == null) {
      return null;
    }
    return servers.firstWhereOrNull((s) => s.id == id);
  }

  Future<void> upsert(Server server) async {
    final pid = projectId;
    if (pid == null) {
      return;
    }
    await AppServices.I.serversStore(pid).upsert(server);
    _logger.info('servers.upsert', data: {'project_id': pid, 'id': server.id});
    await load();
    selectedId.value = server.id;
  }

  Future<void> deleteSelected() async {
    final pid = projectId;
    final id = selectedId.value;
    if (pid == null || id == null) {
      return;
    }
    await AppServices.I.serversStore(pid).delete(id);
    _logger.info('servers.deleted', data: {'project_id': pid, 'id': id});
    selectedId.value = null;
    await load();
  }

  Future<SshExecResult> testSshConnectivity(Server server) async {
    final pid = projectId;
    if (pid == null) {
      throw const AppException(
        code: AppErrorCode.unknown,
        title: '未选择项目',
        message: '当前未选择项目，无法执行测试。',
      );
    }

    final now = DateTime.now();
    testingId.value = server.id;
    testingMode.value = 'ssh';
    try {
      final endpoint = SshEndpoint(
        host: server.ip,
        port: server.port,
        username: server.username,
        password: server.password,
      );
      final r = await AppServices.I.sshService.exec(endpoint, 'uname -a');
      final ok = r.exitCode == 0;
      final updated = server.copyWith(
        lastTestedAt: now,
        lastTestOk: ok,
        lastTestMessage: ok ? 'SSH 登录成功' : '命令退出码：${r.exitCode}',
        lastTestOutput: ok
            ? r.stdout.trim()
            : (r.stderr.trim().isEmpty ? r.stdout.trim() : r.stderr.trim()),
      );
      await AppServices.I.serversStore(pid).upsert(updated);
      await load();
      selectedId.value = updated.id;
      _logger.info(
        'servers.ssh_test',
        data: {'project_id': pid, 'id': server.id, 'ok': ok},
      );
      return r;
    } on AppException catch (e) {
      final updated = server.copyWith(
        lastTestedAt: now,
        lastTestOk: false,
        lastTestMessage: '${e.title}: ${e.message}',
        lastTestOutput: e.cause?.toString() ?? '',
      );
      await AppServices.I.serversStore(pid).upsert(updated);
      await load();
      selectedId.value = updated.id;
      _logger.error(
        'servers.ssh_test.failed',
        data: {'project_id': pid, 'id': server.id, 'error': e.toString()},
      );
      rethrow;
    } finally {
      testingId.value = null;
      testingMode.value = null;
    }
  }

  Future<ControlSelfCheckReport> selfCheckControlEnvironment(
    Server server,
  ) async {
    final pid = projectId;
    if (pid == null) {
      throw const AppException(
        code: AppErrorCode.unknown,
        title: '未选择项目',
        message: '当前未选择项目，无法执行自检。',
      );
    }
    if (server.type != ServerType.control) {
      throw const AppException(
        code: AppErrorCode.validation,
        title: '类型不匹配',
        message: '仅控制端服务器支持环境自检。',
        suggestion: '请选择类型为 control 的服务器。',
      );
    }

    final now = DateTime.now();
    testingId.value = server.id;
    testingMode.value = 'selfcheck';
    try {
      final endpoint = SshEndpoint(
        host: server.ip,
        port: server.port,
        username: server.username,
        password: server.password,
      );

      final report = await AppServices.I.sshService.withConnection(endpoint, (
        conn,
      ) async {
        final lines = <String>[];

        Future<_CheckResult> check(String title, String cmd) async {
          final r = await conn.execWithResult(cmd);
          final ok = r.exitCode == 0;
          final out = [
            '== $title ==',
            '\$ $cmd',
            'exit=${r.exitCode}',
            if (r.stdout.trim().isNotEmpty) 'stdout:\n${r.stdout.trimRight()}',
            if (r.stderr.trim().isNotEmpty) 'stderr:\n${r.stderr.trimRight()}',
            '',
          ].join('\n');
          lines.add(out);
          return _CheckResult(ok: ok, exitCode: r.exitCode);
        }

        final results = <_CheckResult>[
          await check('ansible-playbook', 'ansible-playbook --version'),
          await check('sshpass', 'sshpass -V'),
          await check('unzip', 'unzip -v'),
          await check(
            'run_dir 可写',
            'bash -lc "mkdir -p /tmp/simple_deploy && echo ok > /tmp/simple_deploy/.sd_write_test && test -s /tmp/simple_deploy/.sd_write_test && rm -f /tmp/simple_deploy/.sd_write_test"',
          ),
        ];

        final ok = results.every((x) => x.ok);
        final summary = ok ? '环境自检通过' : '环境自检失败（请根据下方输出定位缺失依赖或权限问题）';

        return ControlSelfCheckReport(
          ok: ok,
          summary: summary,
          details: lines.join('\n'),
        );
      });

      final updated = server.copyWith(
        lastTestedAt: now,
        lastTestOk: report.ok,
        lastTestMessage: report.summary,
        lastTestOutput: report.details,
      );
      await AppServices.I.serversStore(pid).upsert(updated);
      await load();
      selectedId.value = updated.id;

      _logger.info(
        'servers.control_self_check',
        data: {'project_id': pid, 'id': server.id, 'ok': report.ok},
      );
      return report;
    } on AppException catch (e) {
      final updated = server.copyWith(
        lastTestedAt: now,
        lastTestOk: false,
        lastTestMessage: '${e.title}: ${e.message}',
        lastTestOutput: e.cause?.toString() ?? '',
      );
      await AppServices.I.serversStore(pid).upsert(updated);
      await load();
      selectedId.value = updated.id;
      _logger.error(
        'servers.control_self_check.failed',
        data: {'project_id': pid, 'id': server.id, 'error': e.toString()},
      );
      rethrow;
    } finally {
      testingId.value = null;
      testingMode.value = null;
    }
  }
}

class ControlSelfCheckReport {
  final bool ok;
  final String summary;
  final String details;

  const ControlSelfCheckReport({
    required this.ok,
    required this.summary,
    required this.details,
  });
}

class _CheckResult {
  final bool ok;
  final int exitCode;

  const _CheckResult({required this.ok, required this.exitCode});
}
