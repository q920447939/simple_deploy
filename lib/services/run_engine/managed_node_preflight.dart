import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../constants/runtime.dart';
import '../../model/server.dart';
import '../core/app_error.dart';
import '../core/app_logger.dart';
import '../offline_assets/offline_assets.dart';
import '../ssh/ssh_service.dart';

class ManagedNodePreflight {
  final AppLogger logger;
  final OfflineAssets assets;

  const ManagedNodePreflight({required this.logger, required this.assets});

  Future<void> ensurePythonFromControl({
    required SshConnection conn,
    required List<Server> servers,
    required Future<void> Function(String message) logSystem,
    required Directory runArtifacts,
  }) async {
    if (servers.isEmpty) return;
    final manifest = await _loadManifest();
    final bundles = manifest.bundles;
    final venvPy = p.posix.join(manifest.ansibleVenvDir, 'bin', 'python');
    final cacheDir = await _ensureCacheDir(conn, logSystem);
    final remoteDir = '/tmp/simple_deploy/managed_bootstrap';
    await conn.exec('bash -lc ${_shSQ('mkdir -p ${_shDQ(remoteDir)}')}');
    await runArtifacts.create(recursive: true);

    final localScript = assets.file(
      'assets/offline/bootstrap/install_managed_python.sh',
    );
    if (!await localScript.exists()) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: '缺少离线安装脚本',
        message: '未找到 assets/offline/bootstrap/install_managed_python.sh。',
        suggestion: '重新生成离线安装包后重试。',
      );
    }
    final localPreflight = assets.file(
      'assets/offline/bootstrap/managed_preflight.py',
    );
    if (!await localPreflight.exists()) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: '缺少预检脚本',
        message: '未找到 assets/offline/bootstrap/managed_preflight.py。',
        suggestion: '重新生成离线安装包后重试。',
      );
    }

    final remoteInstallScript = p.posix.join(
      cacheDir,
      'install_managed_python.sh',
    );
    final remotePreflight = p.posix.join(cacheDir, 'managed_preflight.py');
    await _ensureCachedFile(
      conn,
      venvPy: venvPy,
      local: localScript,
      remote: remoteInstallScript,
      logSystem: logSystem,
    );
    await _ensureCachedFile(
      conn,
      venvPy: venvPy,
      local: localPreflight,
      remote: remotePreflight,
      logSystem: logSystem,
    );
    await conn.exec('bash -lc ${_shSQ('chmod +x ${_shDQ(remotePreflight)}')}');

    final uploadedArchives = <String, String>{};
    for (final entry in bundles.entries) {
      final key = entry.key;
      final archive = entry.value.pythonArchive;
      if (archive.trim().isEmpty) continue;
      final localArchive = assets.file(archive);
      if (!await localArchive.exists()) {
        throw AppException(
          code: AppErrorCode.unknown,
          title: '缺少 Python 离线安装包',
          message: '未找到：$archive',
          suggestion: '运行 tools/offline/fetch_offline_deps.sh 生成离线安装包后重试。',
        );
      }
      final remoteArchive = p.posix.join(
        cacheDir,
        localArchive.uri.pathSegments.last,
      );
      await _ensureCachedFile(
        conn,
        venvPy: venvPy,
        local: localArchive,
        remote: remoteArchive,
        logSystem: logSystem,
      );
      uploadedArchives[key] = remoteArchive;
    }

    final config = <String, Object?>{
      'python_bin': kRemotePythonPath,
      'python_version': kRemotePythonVersion,
      'install_script': remoteInstallScript,
      'install_dir':
          '/usr/local/simple_deploy/python-${manifest.pythonVersion}',
      'remote_dir': remoteDir,
      'archives': uploadedArchives,
      'servers': [
        for (final s in servers)
          <String, Object?>{
            'id': s.id,
            'host': s.ip,
            'port': s.port,
            'username': s.username,
            'password': s.password,
          },
      ],
    };

    final configFile = File(
      p.join(runArtifacts.path, 'managed_preflight.json'),
    );
    await configFile.writeAsString(jsonEncode(config), flush: true);
    final remoteConfig = '$remoteDir/managed_preflight.json';
    await conn.uploadFile(configFile, remoteConfig);

    final cmd = '$venvPy $remotePreflight --config $remoteConfig';
    await logSystem('preflight.managed.execute');
    final r = await conn.execWithResult('bash -lc ${_shSQ(cmd)}');
    if (r.exitCode != 0) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: '被控端预检失败',
        message: 'exit=${r.exitCode}\n${r.stdout}\n${r.stderr}'.trim(),
        suggestion: '检查被控端连通性、凭据与离线包后重试。',
      );
    }

    final parsed = _parsePreflightResult(r.stdout);
    if (parsed != null && parsed.any((e) => !e.ok)) {
      final failed = parsed.where((e) => !e.ok).toList();
      final summary = failed
          .map((e) => '${e.host}: ${e.error}')
          .take(8)
          .join('\n');
      throw AppException(
        code: AppErrorCode.unknown,
        title: '被控端预检失败',
        message: summary.isEmpty ? '部分被控端未通过预检。' : summary,
        suggestion: '检查被控端连通性、权限与 OS/架构支持后重试。',
      );
    }

    logger.info('managed.preflight.done', data: {'servers': servers.length});
  }

  Future<_ManagedRuntimeManifest> _loadManifest() async {
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
    return _ManagedRuntimeManifest.fromJson(raw.cast<String, Object?>());
  }

  List<_PreflightResult>? _parsePreflightResult(String stdout) {
    final text = stdout.trim();
    if (text.isEmpty) return null;
    final raw = jsonDecode(text);
    if (raw is! Map) return null;
    final results = raw['results'];
    if (results is! List) return null;
    return results
        .whereType<Map>()
        .map((m) => _PreflightResult.fromJson(m.cast<String, Object?>()))
        .toList();
  }

  static String _shDQ(String s) =>
      '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

  static String _shSQ(String s) {
    return "'${s.replaceAll("'", "'\"'\"'")}'";
  }

  Future<String> _ensureCacheDir(
    SshConnection conn,
    Future<void> Function(String message) logSystem,
  ) async {
    const preferred = '/opt/simple_deploy/cache';
    final tryPreferred = await conn.execWithResult(
      'bash -lc ${_shSQ('mkdir -p ${_shDQ(preferred)}')}',
    );
    if (tryPreferred.exitCode == 0) {
      return preferred;
    }
    const fallback = '/tmp/simple_deploy/cache';
    await conn.exec('bash -lc ${_shSQ('mkdir -p ${_shDQ(fallback)}')}');
    await logSystem('preflight.cache.fallback: $fallback');
    return fallback;
  }

  Future<void> _ensureCachedFile(
    SshConnection conn, {
    required String venvPy,
    required File local,
    required String remote,
    required Future<void> Function(String message) logSystem,
  }) async {
    final localHash = await _sha256(local);
    final remoteHash = await _remoteSha256(conn, venvPy, remote);
    if (remoteHash != null && remoteHash == localHash) {
      return;
    }
    await logSystem('preflight.cache.upload: ${p.posix.basename(remote)}');
    await conn.uploadFile(local, remote);
    final verify = await _remoteSha256(conn, venvPy, remote);
    if (verify == null || verify != localHash) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: '控制端缓存校验失败',
        message: '文件 ${p.posix.basename(remote)} 校验不一致。',
        suggestion: '检查控制端磁盘空间与权限后重试。',
      );
    }
  }

  Future<String> _sha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<String?> _remoteSha256(
    SshConnection conn,
    String venvPy,
    String path,
  ) async {
    final code =
        "import hashlib,sys; p=sys.argv[1]; h=hashlib.sha256(); "
        "f=open(p,'rb'); "
        "[h.update(b) for b in iter(lambda: f.read(1048576), b'')]; "
        "f.close(); print(h.hexdigest())";
    final inner = '${_shDQ(venvPy)} -c ${_shDQ(code)} ${_shDQ(path)}';
    final r = await conn.execWithResult('bash -lc ${_shSQ(inner)}');
    if (r.exitCode != 0) return null;
    final out = r.stdout.trim();
    return out.isEmpty ? null : out.split('\n').last.trim();
  }
}

class _ManagedRuntimeManifest {
  final String pythonVersion;
  final String ansibleVenvDir;
  final Map<String, _ManagedBundleManifest> bundles;

  const _ManagedRuntimeManifest({
    required this.pythonVersion,
    required this.ansibleVenvDir,
    required this.bundles,
  });

  factory _ManagedRuntimeManifest.fromJson(Map<String, Object?> json) {
    final python = json['python'];
    final ansible = json['ansible'];
    final bundles = json['bundles'];
    if (python is! Map || ansible is! Map || bundles is! Map) {
      throw const AppException(
        code: AppErrorCode.unknown,
        title: '离线安装包配置损坏',
        message: 'manifest.json 字段缺失或类型不正确。',
        suggestion: '重新生成离线安装包后重试。',
      );
    }
    return _ManagedRuntimeManifest(
      pythonVersion: (python['version'] as String?) ?? '',
      ansibleVenvDir:
          (ansible['venvDir'] as String?) ?? '/opt/simple_deploy/ansible-venv',
      bundles: {
        for (final e in bundles.entries)
          if (e.key is String && e.value is Map)
            e.key as String: _ManagedBundleManifest.fromJson(
              (e.value as Map).cast<String, Object?>(),
            ),
      },
    );
  }
}

class _ManagedBundleManifest {
  final String pythonArchive;

  const _ManagedBundleManifest({required this.pythonArchive});

  factory _ManagedBundleManifest.fromJson(Map<String, Object?> json) {
    return _ManagedBundleManifest(
      pythonArchive: (json['pythonArchive'] as String?) ?? '',
    );
  }
}

class _PreflightResult {
  final String host;
  final bool ok;
  final String error;

  const _PreflightResult({
    required this.host,
    required this.ok,
    required this.error,
  });

  factory _PreflightResult.fromJson(Map<String, Object?> json) {
    return _PreflightResult(
      host: (json['host'] as String?) ?? '',
      ok: (json['ok'] as bool?) ?? false,
      error: (json['error'] as String?) ?? '',
    );
  }
}
