class RunStatus {
  static const String running = 'running';
  static const String ended = 'ended';
}

class RunResult {
  static const String success = 'success';
  static const String failed = 'failed';
}

class TaskExecStatus {
  static const String waiting = 'waiting';
  static const String running = 'running';
  static const String success = 'success';
  static const String failed = 'failed';
}

class BizStatusValue {
  static const String ok = 'ok';
  static const String failed = 'failed';
  static const String unknown = 'unknown';
}

class BizStatus {
  final String status; // ok|failed|unknown
  final String message;
  final String? version;
  final String? timestamp;

  const BizStatus({
    required this.status,
    required this.message,
    this.version,
    this.timestamp,
  });

  static BizStatus fromJson(Map<String, Object?> json) {
    return BizStatus(
      status: (json['status'] as String?) ?? BizStatusValue.unknown,
      message: (json['message'] as String?) ?? '',
      version: json['version'] as String?,
      timestamp: json['timestamp'] as String?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'status': status,
      'message': message,
      'version': version,
      'timestamp': timestamp,
    };
  }
}

class TaskRunResult {
  final String taskId;
  final String status; // waiting|running|success|failed
  final int? exitCode;
  final Map<String, List<String>>? fileInputs; // slot -> relative paths
  final Map<String, String>? vars; // var_name -> value (effective)
  final String? error;

  const TaskRunResult({
    required this.taskId,
    required this.status,
    required this.exitCode,
    required this.fileInputs,
    required this.vars,
    required this.error,
  });

  TaskRunResult copyWith({
    String? status,
    int? exitCode,
    Map<String, List<String>>? fileInputs,
    Map<String, String>? vars,
    String? error,
  }) {
    return TaskRunResult(
      taskId: taskId,
      status: status ?? this.status,
      exitCode: exitCode ?? this.exitCode,
      fileInputs: fileInputs ?? this.fileInputs,
      vars: vars ?? this.vars,
      error: error ?? this.error,
    );
  }

  static TaskRunResult fromJson(Map<String, Object?> json) {
    Map<String, List<String>>? fileInputs;
    final raw = json['file_inputs'];
    if (raw is Map) {
      fileInputs = raw.map((k, v) {
        final list = (v as List?)?.cast<String>().toList() ?? <String>[];
        return MapEntry(k as String, list);
      });
    }
    Map<String, String>? vars;
    final rawVars = json['vars'];
    if (rawVars is Map) {
      vars = <String, String>{};
      for (final e in rawVars.entries) {
        if (e.key is! String) continue;
        final k = e.key as String;
        final v = e.value;
        if (v == null) continue;
        vars[k] = v.toString();
      }
    }
    return TaskRunResult(
      taskId: json['task_id'] as String,
      status: (json['status'] as String?) ?? TaskExecStatus.waiting,
      exitCode: (json['exit_code'] as num?)?.toInt(),
      fileInputs: fileInputs,
      vars: vars,
      error: json['error'] as String?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'task_id': taskId,
      'status': status,
      'exit_code': exitCode,
      'file_inputs': fileInputs,
      'vars': vars,
      'error': error,
    };
  }
}

class Run {
  final String id;
  final String projectId;
  final String batchId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String status; // running|ended
  final String result; // success|failed
  final List<TaskRunResult> taskResults;
  final Map<String, Object?>? ansibleSummary;
  final BizStatus? bizStatus;
  final String? errorSummary;

  const Run({
    required this.id,
    required this.projectId,
    required this.batchId,
    required this.startedAt,
    required this.endedAt,
    required this.status,
    required this.result,
    required this.taskResults,
    required this.ansibleSummary,
    required this.bizStatus,
    required this.errorSummary,
  });

  Run copyWith({
    DateTime? endedAt,
    String? status,
    String? result,
    List<TaskRunResult>? taskResults,
    Map<String, Object?>? ansibleSummary,
    BizStatus? bizStatus,
    String? errorSummary,
  }) {
    return Run(
      id: id,
      projectId: projectId,
      batchId: batchId,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      status: status ?? this.status,
      result: result ?? this.result,
      taskResults: taskResults ?? this.taskResults,
      ansibleSummary: ansibleSummary ?? this.ansibleSummary,
      bizStatus: bizStatus ?? this.bizStatus,
      errorSummary: errorSummary ?? this.errorSummary,
    );
  }

  static Run fromJson(Map<String, Object?> json) {
    final trs =
        (json['task_results'] as List?)?.whereType<Map>().toList() ?? const [];
    return Run(
      id: json['id'] as String,
      projectId: json['project_id'] as String,
      batchId: json['batch_id'] as String,
      startedAt: DateTime.parse(json['started_at'] as String),
      endedAt: json['ended_at'] == null
          ? null
          : DateTime.parse(json['ended_at'] as String),
      status: (json['status'] as String?) ?? RunStatus.running,
      result: (json['result'] as String?) ?? RunResult.failed,
      taskResults: trs
          .map((m) => TaskRunResult.fromJson(m.cast<String, Object?>()))
          .toList(),
      ansibleSummary: (json['ansible_summary'] as Map?)
          ?.cast<String, Object?>(),
      bizStatus: json['biz_status'] == null
          ? null
          : BizStatus.fromJson(
              (json['biz_status'] as Map).cast<String, Object?>(),
            ),
      errorSummary: json['error_summary'] as String?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'project_id': projectId,
      'batch_id': batchId,
      'started_at': startedAt.toIso8601String(),
      'ended_at': endedAt?.toIso8601String(),
      'status': status,
      'result': result,
      'task_results': taskResults.map((t) => t.toJson()).toList(),
      'ansible_summary': ansibleSummary,
      'biz_status': bizStatus?.toJson(),
      'error_summary': errorSummary,
    };
  }
}
