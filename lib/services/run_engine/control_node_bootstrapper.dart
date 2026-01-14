import 'dart:convert';

import '../../services/core/app_error.dart';
import '../../services/core/app_logger.dart';
import '../../services/offline_assets/offline_assets.dart';
import '../ssh/ssh_service.dart';

class ControlRuntimeInfo {
  final String pythonBin;
  final String ansiblePlaybook;

  const ControlRuntimeInfo({
    required this.pythonBin,
    required this.ansiblePlaybook,
  });
}

class ControlNodeBootstrapper {
  final SshConnection conn;
  final SshEndpoint endpoint;
  final AppLogger logger;
  final OfflineAssets assets;
  final bool allowUnsupportedOsAutoInstall;
  final String controlOsHint;

  const ControlNodeBootstrapper({
    required this.conn,
    required this.endpoint,
    required this.logger,
    required this.assets,
    this.allowUnsupportedOsAutoInstall = false,
    this.controlOsHint = 'auto',
  });

  Future<ControlRuntimeInfo> ensureReady() async {
    final manifest = await _loadManifest();

    final os = await _readOsRelease();
    final arch = await _readArch();

    final supported = _isSupported(
      os: os,
      arch: arch,
      controlOsHint: controlOsHint,
    );
    logger.info(
      'control.bootstrap.detected',
      data: {
        'os': os.toJson(),
        'arch': arch,
        'supported': supported,
        'control_os_hint': controlOsHint,
      },
    );

    final pythonOk = await _hasPython312();
    final ansibleOk =
        (await _hasAnsible(manifest.ansible.ansiblePlaybookPath)) &&
        (await _hasAnsibleExtras(manifest.ansible));
    final unzipOk = await _hasCommand('unzip');
    final sshpassOk = await _hasCommand('sshpass');

    final needRequired = !pythonOk || !ansibleOk;
    final needOptional = !unzipOk || !sshpassOk;

    if (needRequired || (supported && needOptional)) {
      if (!supported && needRequired) {
        final detected =
            '检测到: ${os.prettyName ?? 'unknown'} (id=${os.id ?? '?'}, version_id=${os.versionId ?? '?'}, version=${os.version ?? '?'}) arch=$arch';
        if (!allowUnsupportedOsAutoInstall) {
          throw AppException(
            code: AppErrorCode.unknown,
            title: '控制端不支持自动安装',
            message:
                '当前仅支持 Ubuntu 24+ 与 银河麒麟 V10 SP3（x86_64/aarch64）。\n$detected',
            suggestion: '请手工在控制端安装 python3.12 与 ansible 后重试。',
          );
        }
        logger.warn(
          'control.bootstrap.unsupported_os_auto_install_forced',
          data: {'os': os.toJson(), 'arch': arch},
        );
      }

      await _installIfNeeded(
        manifest: manifest,
        arch: arch,
        needPython: !pythonOk,
        needAnsible: !ansibleOk,
        needUnzip: !unzipOk,
        needSshpass: !sshpassOk,
      );
    }

    // Tools are best-effort; missing tools should not block execution because
    // the runner has fallbacks (Python unzip; Paramiko SSH for Ansible).
    if (!await _hasCommand('unzip')) {
      logger.warn('control.bootstrap.tool.missing', data: {'tool': 'unzip'});
    }
    if (!await _hasCommand('sshpass')) {
      logger.warn('control.bootstrap.tool.missing', data: {'tool': 'sshpass'});
    }

    final ansiblePath =
        (await _hasAnsible(manifest.ansible.ansiblePlaybookPath))
        ? manifest.ansible.ansiblePlaybookPath
        : 'ansible-playbook';

    if (!await _hasPython312()) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: '控制端 Python 安装失败',
        message: '未检测到 python3.12。',
        suggestion: '检查控制端执行日志，或手工安装 python3.12 后重试。',
      );
    }
    if (!await _hasAnsible(ansiblePath)) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: '控制端 Ansible 安装失败',
        message: '未检测到 ansible-playbook。',
        suggestion: '检查控制端执行日志，或手工安装 ansible 后重试。',
      );
    }

    return ControlRuntimeInfo(
      pythonBin: manifest.python.binPath,
      ansiblePlaybook: ansiblePath,
    );
  }

  Future<_ControlRuntimeManifest> _loadManifest() async {
    final f = assets.file('assets/offline/manifest.json');
    if (!await f.exists()) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: '缺少离线安装包',
        message: '未找到 assets/offline/manifest.json。',
        suggestion: '运行 tools/offline/fetch_offline_deps.sh 生成离线安装包后重试。',
      );
    }
    final raw = jsonDecode(await f.readAsString());
    if (raw is! Map) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: '离线安装包配置损坏',
        message: 'manifest.json 不是合法 JSON 对象。',
        suggestion: '重新生成离线安装包后重试。',
      );
    }
    return _ControlRuntimeManifest.fromJson(raw.cast<String, Object?>());
  }

  Future<_OsRelease> _readOsRelease() async {
    final r = await conn.execWithResult('cat /etc/os-release');
    if (r.exitCode != 0) {
      return const _OsRelease(values: {});
    }
    return _OsRelease.parse(r.stdout);
  }

  Future<String> _readArch() async {
    final r = await conn.execWithResult('uname -m');
    if (r.exitCode != 0) return 'unknown';
    return r.stdout.trim();
  }

  bool _isSupported({
    required _OsRelease os,
    required String arch,
    required String controlOsHint,
  }) {
    final isArchOk = arch == 'x86_64' || arch == 'aarch64' || arch == 'arm64';
    if (!isArchOk) return false;

    if (controlOsHint == 'ubuntu24+') {
      return true;
    }
    if (controlOsHint == 'kylin_v10_sp3') {
      return true;
    }
    if (controlOsHint == 'other') {
      return false;
    }

    final id = (os.id ?? '').toLowerCase();
    final pretty = (os.prettyName ?? '').toLowerCase();
    final versionId = (os.versionId ?? '').toLowerCase();
    final version = (os.version ?? '').toLowerCase();

    if (id == 'ubuntu') {
      final v = double.tryParse(versionId.replaceAll('"', ''));
      return v != null && v >= 24.0;
    }

    final looksKylin =
        id.contains('kylin') ||
        pretty.contains('kylin') ||
        pretty.contains('麒麟');
    final looksV10 =
        versionId.contains('v10') ||
        version.contains('v10') ||
        pretty.contains('v10');
    final looksSp3 = version.contains('sp3') || pretty.contains('sp3');
    return looksKylin && looksV10 && looksSp3;
  }

  Future<bool> _hasPython312() async {
    final r = await conn.execWithResult(
      'bash -lc "command -v python3.12 >/dev/null 2>&1 && python3.12 -c \\"import sys; raise SystemExit(0 if sys.version_info[:2]==(3,12) else 3)\\""',
    );
    return r.exitCode == 0;
  }

  Future<bool> _hasAnsible(String ansiblePlaybookPath) async {
    final cmd = ansiblePlaybookPath == 'ansible-playbook'
        ? 'bash -lc "command -v ansible-playbook >/dev/null 2>&1 && ansible-playbook --version >/dev/null 2>&1"'
        : 'bash -lc "test -x ${_shDQ(ansiblePlaybookPath)} && ${_shDQ(ansiblePlaybookPath)} --version >/dev/null 2>&1"';
    final r = await conn.execWithResult(cmd);
    return r.exitCode == 0;
  }

  Future<bool> _hasAnsibleExtras(_AnsibleManifest ansible) async {
    if (ansible.extraPip.isEmpty) return true;
    final venvPy = '${ansible.venvDir}/bin/python';
    for (final spec in ansible.extraPip) {
      final name = spec.split(RegExp(r'[<>=!]')).first.trim().toLowerCase();
      if (name == 'paramiko') {
        final r = await conn.execWithResult(
          'bash -lc "test -x ${_shDQ(venvPy)} && ${_shDQ(venvPy)} -c \\"import paramiko\\""',
        );
        if (r.exitCode != 0) return false;
      }
    }
    return true;
  }

  Future<bool> _hasCommand(String name) async {
    final r = await conn.execWithResult(
      'bash -lc "command -v ${_shDQ(name)} >/dev/null 2>&1"',
    );
    return r.exitCode == 0;
  }

  Future<void> _installIfNeeded({
    required _ControlRuntimeManifest manifest,
    required String arch,
    required bool needPython,
    required bool needAnsible,
    required bool needUnzip,
    required bool needSshpass,
  }) async {
    final bundleKey = _bundleKeyForArch(arch);
    final bundle = manifest.bundles[bundleKey];
    if (bundle == null) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: '缺少离线安装包',
        message: '不支持的架构：$arch',
        suggestion: '请为该架构准备离线安装包后重试。',
      );
    }

    final remoteDir = '/tmp/simple_deploy/bootstrap';
    await conn.exec('bash -lc "mkdir -p ${_shDQ(remoteDir)}"');

    final remoteScript = '$remoteDir/install_control_runtime.sh';
    final localScript = assets.file(
      'assets/offline/bootstrap/install_control_runtime.sh',
    );
    if (!await localScript.exists()) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: '缺少离线安装脚本',
        message: '未找到 assets/offline/bootstrap/install_control_runtime.sh。',
        suggestion: '重新生成离线安装包后重试。',
      );
    }
    await conn.uploadFile(localScript, remoteScript);

    String? remotePyArchive;
    if (needPython) {
      final localPy = assets.file(bundle.pythonArchive);
      if (!await localPy.exists()) {
        throw AppException(
          code: AppErrorCode.unknown,
          title: '缺少 Python 离线安装包',
          message: '未找到：${bundle.pythonArchive}',
          suggestion: '运行 tools/offline/fetch_offline_deps.sh 生成离线安装包后重试。',
        );
      }
      remotePyArchive = '$remoteDir/${localPy.uri.pathSegments.last}';
      await conn.uploadFile(localPy, remotePyArchive);
    }

    String? remoteWheelArchive;
    if (needAnsible) {
      final localWh = assets.file(bundle.ansibleWheelhouseArchive);
      if (!await localWh.exists()) {
        throw AppException(
          code: AppErrorCode.unknown,
          title: '缺少 Ansible 离线安装包',
          message: '未找到：${bundle.ansibleWheelhouseArchive}',
          suggestion: '运行 tools/offline/fetch_offline_deps.sh 生成离线安装包后重试。',
        );
      }
      remoteWheelArchive = '$remoteDir/${localWh.uri.pathSegments.last}';
      await conn.uploadFile(localWh, remoteWheelArchive);
    }

    String? remoteSshpassDeb;
    String? remoteUnzipDeb;
    if (needSshpass) {
      final deb = bundle.ubuntuDebs['sshpass'];
      if (deb != null && deb.isNotEmpty) {
        final local = assets.file(deb);
        if (await local.exists()) {
          remoteSshpassDeb = '$remoteDir/${local.uri.pathSegments.last}';
          await conn.uploadFile(local, remoteSshpassDeb);
        }
      }
    }
    if (needUnzip) {
      final deb = bundle.ubuntuDebs['unzip'];
      if (deb != null && deb.isNotEmpty) {
        final local = assets.file(deb);
        if (await local.exists()) {
          remoteUnzipDeb = '$remoteDir/${local.uri.pathSegments.last}';
          await conn.uploadFile(local, remoteUnzipDeb);
        }
      }
    }

    await conn.exec('bash -lc "chmod +x ${_shDQ(remoteScript)}"');

    final args = <String>[
      '--python-archive',
      remotePyArchive ?? '/dev/null',
      '--python-install-dir',
      manifest.python.installDir,
      '--python-bin',
      manifest.python.binPath,
      '--ansible-wheelhouse-archive',
      remoteWheelArchive ?? '/dev/null',
      '--ansible-version',
      manifest.ansible.version,
      '--ansible-venv',
      manifest.ansible.venvDir,
      for (final extra in manifest.ansible.extraPip) ...[
        '--ansible-extra',
        extra,
      ],
      '--sshpass-deb',
      remoteSshpassDeb ?? '/dev/null',
      '--unzip-deb',
      remoteUnzipDeb ?? '/dev/null',
    ].map(_shDQ).join(' ');

    final installCmd = '${_shDQ(remoteScript)} $args';

    final full = needPython || needAnsible || needUnzip || needSshpass;
    if (!full) return;

    final wrapped = await _wrapWithSudoIfNeeded(installCmd);
    final r = await conn.execWithResult(wrapped);
    if (r.exitCode != 0) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: '控制端自动安装失败',
        message: 'exit=${r.exitCode}\n${r.stdout}\n${r.stderr}'.trim(),
        suggestion: '检查控制端系统依赖、磁盘空间与 sudo 配置后重试。',
      );
    }
  }

  Future<String> _wrapWithSudoIfNeeded(String cmd) async {
    final id = await conn.execWithResult('id -u');
    if (id.exitCode == 0 && id.stdout.trim() == '0') {
      return 'bash -lc ${_shSQ(cmd)}';
    }

    final sudoNoPass = await conn.execWithResult('sudo -n true');
    if (sudoNoPass.exitCode == 0) {
      return 'bash -lc ${_shSQ('sudo -n /bin/bash -lc ${_shSQ(cmd)}')}';
    }

    if (endpoint.password.contains('\n')) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: 'sudo 密码不支持',
        message: '控制端密码包含换行符，无法用于 sudo 自动安装。',
        suggestion: '请使用不包含换行的密码，或配置 NOPASSWD sudo。',
      );
    }

    final pw = _shSQ(endpoint.password);
    final inner = '/bin/bash -lc ${_shSQ(cmd)}';
    final sudo = "printf '%s\\n' $pw | sudo -S -p '' $inner";
    return 'bash -lc ${_shSQ(sudo)}';
  }

  static String _bundleKeyForArch(String arch) {
    final a = arch.trim();
    if (a == 'x86_64' || a == 'amd64') return 'linux-x86_64';
    if (a == 'aarch64' || a == 'arm64') return 'linux-aarch64';
    return 'linux-$a';
  }

  static String _shDQ(String s) =>
      '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

  static String _shSQ(String s) {
    // POSIX-safe single-quote escaping: ' -> '"'"'
    return "'${s.replaceAll("'", "'\"'\"'")}'";
  }
}

class _ControlRuntimeManifest {
  final int schemaVersion;
  final _PythonManifest python;
  final _AnsibleManifest ansible;
  final Map<String, _BundleManifest> bundles;

  const _ControlRuntimeManifest({
    required this.schemaVersion,
    required this.python,
    required this.ansible,
    required this.bundles,
  });

  factory _ControlRuntimeManifest.fromJson(Map<String, Object?> json) {
    final schema = json['schemaVersion'];
    final python = json['python'];
    final ansible = json['ansible'];
    final bundles = json['bundles'];
    if (schema is! int ||
        python is! Map ||
        ansible is! Map ||
        bundles is! Map) {
      throw const AppException(
        code: AppErrorCode.unknown,
        title: '离线安装包配置损坏',
        message: 'manifest.json 字段缺失或类型不正确。',
        suggestion: '重新生成离线安装包后重试。',
      );
    }
    return _ControlRuntimeManifest(
      schemaVersion: schema,
      python: _PythonManifest.fromJson(python.cast<String, Object?>()),
      ansible: _AnsibleManifest.fromJson(ansible.cast<String, Object?>()),
      bundles: {
        for (final e in bundles.entries)
          if (e.key is String && e.value is Map)
            e.key as String: _BundleManifest.fromJson(
              (e.value as Map).cast<String, Object?>(),
            ),
      },
    );
  }
}

class _PythonManifest {
  final String version;
  final String provider;
  final String providerTag;
  final String installDir;
  final String binPath;

  const _PythonManifest({
    required this.version,
    required this.provider,
    required this.providerTag,
    required this.installDir,
    required this.binPath,
  });

  factory _PythonManifest.fromJson(Map<String, Object?> json) {
    return _PythonManifest(
      version: (json['version'] as String?) ?? '',
      provider: (json['provider'] as String?) ?? '',
      providerTag: (json['providerTag'] as String?) ?? '',
      installDir: (json['installDir'] as String?) ?? '',
      binPath: (json['binPath'] as String?) ?? '/usr/bin/python3.12',
    );
  }
}

class _AnsibleManifest {
  final String version;
  final String venvDir;
  final String ansiblePlaybookPath;
  final List<String> extraPip;

  const _AnsibleManifest({
    required this.version,
    required this.venvDir,
    required this.ansiblePlaybookPath,
    required this.extraPip,
  });

  factory _AnsibleManifest.fromJson(Map<String, Object?> json) {
    final extraRaw = json['extraPip'];
    final extras = <String>[
      if (extraRaw is List)
        for (final x in extraRaw)
          if (x is String && x.trim().isNotEmpty) x.trim(),
    ];
    return _AnsibleManifest(
      version: (json['version'] as String?) ?? '',
      venvDir:
          (json['venvDir'] as String?) ?? '/opt/simple_deploy/ansible-venv',
      ansiblePlaybookPath:
          (json['ansiblePlaybookPath'] as String?) ??
          '/opt/simple_deploy/ansible-venv/bin/ansible-playbook',
      extraPip: extras,
    );
  }
}

class _BundleManifest {
  final String pythonArchive;
  final String ansibleWheelhouseArchive;
  final Map<String, String> ubuntuDebs;

  const _BundleManifest({
    required this.pythonArchive,
    required this.ansibleWheelhouseArchive,
    required this.ubuntuDebs,
  });

  factory _BundleManifest.fromJson(Map<String, Object?> json) {
    final rawDebs = json['ubuntuDebs'];
    final debs = <String, String>{};
    if (rawDebs is Map) {
      for (final e in rawDebs.entries) {
        final k = e.key;
        final v = e.value;
        if (k is String && v is String) {
          debs[k] = v;
        }
      }
    }
    return _BundleManifest(
      pythonArchive: (json['pythonArchive'] as String?) ?? '',
      ansibleWheelhouseArchive:
          (json['ansibleWheelhouseArchive'] as String?) ?? '',
      ubuntuDebs: debs,
    );
  }
}

class _OsRelease {
  final Map<String, String> values;

  const _OsRelease({required this.values});

  String? get id => values['ID'];
  String? get versionId => values['VERSION_ID'];
  String? get version => values['VERSION'];
  String? get prettyName => values['PRETTY_NAME'];

  static _OsRelease parse(String text) {
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
    return _OsRelease(values: map);
  }

  Map<String, Object?> toJson() => values;
}
