import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../core/app_error.dart';

class SshEndpoint {
  final String host;
  final int port;
  final String username;
  final String password;

  const SshEndpoint({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
  });
}

class SshExecResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const SshExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
}

class SshService {
  static const Duration _defaultConnectTimeout = Duration(seconds: 8);
  static const Duration _defaultInitTimeout = Duration(seconds: 12);

  Future<T> withConnection<T>(
    SshEndpoint endpoint,
    Future<T> Function(SshConnection conn) fn, {
    Duration connectTimeout = _defaultConnectTimeout,
    Duration initTimeout = _defaultInitTimeout,
  }) async {
    try {
      final socket = await SSHSocket.connect(
        endpoint.host,
        endpoint.port,
        timeout: connectTimeout,
      );
      final client = SSHClient(
        socket,
        username: endpoint.username,
        onPasswordRequest: () => endpoint.password,
      );
      final conn = SshConnection._(socket: socket, client: client);
      try {
        await conn._init().timeout(initTimeout);
        return await fn(conn);
      } finally {
        conn.close();
      }
    } on AppException {
      rethrow;
    } on TimeoutException catch (e) {
      throw AppException(
        code: AppErrorCode.sshTimeout,
        title: 'SSH 连接超时',
        message: '连接 ${endpoint.host}:${endpoint.port} 超时。',
        suggestion: '检查网络连通性与端口放行，确认控制端 SSH 服务正常。',
        cause: e,
      );
    } on SocketException catch (e) {
      final mapped = _mapSocketException(e);
      throw AppException(
        code: AppErrorCode.sshNetwork,
        title: mapped.title,
        message: '无法连接 ${endpoint.host}:${endpoint.port}（${mapped.message}）。',
        suggestion: '检查 IP/端口、网络路由、防火墙与控制端 SSH 服务。',
        cause: e,
      );
    } on SSHAuthFailError catch (e) {
      throw AppException(
        code: AppErrorCode.sshAuthFailed,
        title: 'SSH 认证失败',
        message: '用户名或密码错误，无法登录 ${endpoint.host}:${endpoint.port}。',
        suggestion: '检查用户名/密码是否正确，或确认控制端允许密码登录。',
        cause: e,
      );
    } on SSHAuthAbortError catch (e) {
      throw AppException(
        code: AppErrorCode.sshAuthFailed,
        title: 'SSH 认证中断',
        message: '认证过程中连接中断，无法登录 ${endpoint.host}:${endpoint.port}。',
        suggestion: '检查网络稳定性与控制端 SSH 服务状态后重试。',
        cause: e,
      );
    } on SSHHandshakeError catch (e) {
      throw AppException(
        code: AppErrorCode.sshHandshake,
        title: 'SSH 握手失败',
        message: '与 ${endpoint.host}:${endpoint.port} 协商失败：${e.message}',
        suggestion: '确认目标是 SSH 服务端口，且协议/算法兼容；必要时升级控制端 SSH。',
        cause: e,
      );
    } on SSHHostkeyError catch (e) {
      throw AppException(
        code: AppErrorCode.sshHostkey,
        title: 'SSH 主机密钥校验失败',
        message:
            '与 ${endpoint.host}:${endpoint.port} 建立连接时主机密钥校验失败：${e.message}',
        suggestion: '检查目标主机是否变更，或确认连接的确是预期的控制端。',
        cause: e,
      );
    } on SSHSocketError catch (e) {
      throw AppException(
        code: AppErrorCode.sshNetwork,
        title: 'SSH Socket 错误',
        message: '底层连接错误，无法连接 ${endpoint.host}:${endpoint.port}。',
        suggestion: '检查网络连通性与端口放行，确认控制端 SSH 服务正常。',
        cause: e,
      );
    } on Object catch (e) {
      throw AppException(
        code: AppErrorCode.unknown,
        title: 'SSH 连接失败',
        message: '无法建立 SSH 连接或执行远程操作。',
        suggestion: '检查 IP/端口/密码，确认控制端 SSH 可达。',
        cause: e,
      );
    }
  }

  Future<SshExecResult> exec(SshEndpoint endpoint, String command) async {
    try {
      return await withConnection(
        endpoint,
        (conn) => conn.execWithResult(command),
      );
    } on AppException {
      rethrow;
    } on Object catch (e) {
      throw AppException(
        code: AppErrorCode.sshExec,
        title: 'SSH 执行失败',
        message: '远程命令执行失败：$command',
        suggestion: '检查控制端环境与权限，或重试。',
        cause: e,
      );
    }
  }
}

class SshConnection {
  final SSHSocket socket;
  final SSHClient client;
  SftpClient? _sftp;

  SshConnection._({required this.socket, required this.client});

  Future<void> _init() async {
    _sftp = await client.sftp();
  }

  void close() {
    client.close();
    socket.close();
  }

  Future<SshExecResult> execWithResult(String command) async {
    final session = await client.execute(command);
    final stdoutFuture = utf8.decodeStream(session.stdout);
    final stderrFuture = utf8.decodeStream(session.stderr);
    await session.done;
    final out = await stdoutFuture;
    final err = await stderrFuture;
    final code = session.exitCode ?? -1;
    return SshExecResult(exitCode: code, stdout: out, stderr: err);
  }

  Future<int> exec(String command) async {
    final r = await execWithResult(command);
    return r.exitCode;
  }

  Future<int> execStream(
    String command, {
    void Function(String chunk)? onStdout,
    void Function(String chunk)? onStderr,
  }) async {
    final session = await client.execute(command);
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();

    session.stdout
        .map((data) => data as List<int>)
        .transform(utf8.decoder)
        .listen(
          (s) => onStdout?.call(s),
          onDone: stdoutDone.complete,
          onError: stdoutDone.completeError,
        );
    session.stderr
        .map((data) => data as List<int>)
        .transform(utf8.decoder)
        .listen(
          (s) => onStderr?.call(s),
          onDone: stderrDone.complete,
          onError: stderrDone.completeError,
        );

    await session.done;
    await stdoutDone.future;
    await stderrDone.future;
    return session.exitCode ?? -1;
  }

  Future<void> uploadFile(
    File local,
    String remotePath, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final sftp = _sftp;
    if (sftp == null) {
      throw StateError('SFTP not initialized.');
    }
    final remote = await sftp.open(
      remotePath,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      final total = await local.length();
      var sent = 0;
      onProgress?.call(0, total);
      final stream = local.openRead().map((chunk) {
        final data = Uint8List.fromList(chunk);
        sent += data.length;
        onProgress?.call(sent, total);
        return data;
      });
      await remote.write(stream).done;
    } finally {
      await remote.close();
    }
  }

  Future<String?> readFileOrNull(String remotePath) async {
    final sftp = _sftp;
    if (sftp == null) {
      throw StateError('SFTP not initialized.');
    }
    try {
      final f = await sftp.open(remotePath, mode: SftpFileOpenMode.read);
      try {
        final bytes = await f.readBytes();
        return utf8.decode(bytes, allowMalformed: true);
      } finally {
        await f.close();
      }
    } on SftpStatusError {
      return null;
    } on SftpError {
      return null;
    }
  }
}

class _SocketExceptionMapping {
  final String title;
  final String message;

  const _SocketExceptionMapping({required this.title, required this.message});
}

_SocketExceptionMapping _mapSocketException(SocketException e) {
  final code = e.osError?.errorCode;
  final msg = e.message.toLowerCase();

  bool containsAny(List<String> parts) =>
      parts.any((p) => msg.contains(p.toLowerCase()));

  if (code == 111 || containsAny(['connection refused'])) {
    return const _SocketExceptionMapping(
      title: '端口拒绝连接',
      message: '对端拒绝连接（可能端口未开放或 SSH 未启动）',
    );
  }
  if (code == 110 || containsAny(['timed out', 'timeout'])) {
    return const _SocketExceptionMapping(
      title: '连接超时',
      message: '连接超时（可能网络不通或被防火墙丢弃）',
    );
  }
  if (code == 113 || containsAny(['no route to host'])) {
    return const _SocketExceptionMapping(
      title: '网络不可达',
      message: '无路由到主机（可能路由/网段/安全组问题）',
    );
  }
  if (code == 101 || containsAny(['network is unreachable'])) {
    return const _SocketExceptionMapping(
      title: '网络不可达',
      message: '网络不可达（可能本机网络/路由问题）',
    );
  }
  return _SocketExceptionMapping(title: '网络错误', message: e.message);
}
