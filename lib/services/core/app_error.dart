class AppErrorCode {
  static const String unknown = 'unknown';
  static const String storageIo = 'storage.io';
  static const String storageCorruptJson = 'storage.corrupt_json';
  static const String projectNameConflict = 'project.name_conflict';
  static const String validation = 'validation';
  static const String yamlInvalid = 'playbook.yaml_invalid';
  static const String batchLocked = 'batch.locked';
  static const String sshTimeout = 'ssh.timeout';
  static const String sshNetwork = 'ssh.network';
  static const String sshHandshake = 'ssh.handshake';
  static const String sshAuthFailed = 'ssh.auth_failed';
  static const String sshHostkey = 'ssh.hostkey';
  static const String sshExec = 'ssh.exec';
}

class AppException implements Exception {
  final String code;
  final String title;
  final String message;
  final String? suggestion;
  final Object? cause;

  const AppException({
    required this.code,
    required this.title,
    required this.message,
    this.suggestion,
    this.cause,
  });

  @override
  String toString() {
    return 'AppException($code): $title - $message';
  }
}
