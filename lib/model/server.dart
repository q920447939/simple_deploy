class ServerType {
  static const String control = 'control';
  static const String managed = 'managed';
}

class ControlOsHint {
  static const String auto = 'auto';
  static const String ubuntu24Plus = 'ubuntu24+';
  static const String kylinV10Sp3 = 'kylin_v10_sp3';
  static const String other = 'other';
}

class Server {
  final String id;
  final String name;
  final String type; // control | managed
  final String ip;
  final int port;
  final String username;
  final String password;
  final bool enabled;
  final String controlOsHint;
  final DateTime? lastTestedAt;
  final bool? lastTestOk;
  final String? lastTestMessage;
  final String? lastTestOutput;

  const Server({
    required this.id,
    required this.name,
    required this.type,
    required this.ip,
    required this.port,
    required this.username,
    required this.password,
    required this.enabled,
    this.controlOsHint = ControlOsHint.auto,
    this.lastTestedAt,
    this.lastTestOk,
    this.lastTestMessage,
    this.lastTestOutput,
  });

  Server copyWith({
    String? name,
    String? type,
    String? ip,
    int? port,
    String? username,
    String? password,
    bool? enabled,
    String? controlOsHint,
    DateTime? lastTestedAt,
    bool? lastTestOk,
    String? lastTestMessage,
    String? lastTestOutput,
  }) {
    return Server(
      id: id,
      name: name ?? this.name,
      type: type ?? this.type,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      enabled: enabled ?? this.enabled,
      controlOsHint: controlOsHint ?? this.controlOsHint,
      lastTestedAt: lastTestedAt ?? this.lastTestedAt,
      lastTestOk: lastTestOk ?? this.lastTestOk,
      lastTestMessage: lastTestMessage ?? this.lastTestMessage,
      lastTestOutput: lastTestOutput ?? this.lastTestOutput,
    );
  }

  static Server fromJson(Map<String, Object?> json) {
    final hint = (json['control_os_hint'] as String?)?.trim();
    return Server(
      id: json['id'] as String,
      name: json['name'] as String,
      type: json['type'] as String,
      ip: json['ip'] as String,
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: (json['username'] as String?) ?? 'root',
      password: (json['password'] as String?) ?? '',
      enabled: (json['enabled'] as bool?) ?? true,
      controlOsHint: hint == null || hint.isEmpty ? ControlOsHint.auto : hint,
      lastTestedAt: (json['last_tested_at'] as String?) == null
          ? null
          : DateTime.tryParse(json['last_tested_at'] as String),
      lastTestOk: json['last_test_ok'] as bool?,
      lastTestMessage: json['last_test_message'] as String?,
      lastTestOutput: json['last_test_output'] as String?,
    );
  }

  Map<String, Object?> toJson() {
    final m = <String, Object?>{
      'id': id,
      'name': name,
      'type': type,
      'ip': ip,
      'port': port,
      'username': username,
      'password': password,
      'enabled': enabled,
    };
    if (controlOsHint != ControlOsHint.auto) {
      m['control_os_hint'] = controlOsHint;
    }
    if (lastTestedAt != null) {
      m['last_tested_at'] = lastTestedAt!.toIso8601String();
    }
    if (lastTestOk != null) {
      m['last_test_ok'] = lastTestOk;
    }
    if (lastTestMessage != null) {
      m['last_test_message'] = lastTestMessage;
    }
    if (lastTestOutput != null) {
      m['last_test_output'] = lastTestOutput;
    }
    return m;
  }
}
