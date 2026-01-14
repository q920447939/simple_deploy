class BatchStatus {
  static const String paused = 'paused';
  static const String running = 'running';
  static const String ended = 'ended';
}

class Batch {
  final String id;
  final String name;
  final String description;
  final String status; // paused | running | ended
  final String controlServerId;
  final List<String> managedServerIds;
  final List<String> taskOrder;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? lastRunId;

  const Batch({
    required this.id,
    required this.name,
    required this.description,
    required this.status,
    required this.controlServerId,
    required this.managedServerIds,
    required this.taskOrder,
    required this.createdAt,
    required this.updatedAt,
    required this.lastRunId,
  });

  Batch copyWith({
    String? name,
    String? description,
    String? status,
    String? controlServerId,
    List<String>? managedServerIds,
    List<String>? taskOrder,
    DateTime? updatedAt,
    String? lastRunId,
  }) {
    return Batch(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      status: status ?? this.status,
      controlServerId: controlServerId ?? this.controlServerId,
      managedServerIds: managedServerIds ?? this.managedServerIds,
      taskOrder: taskOrder ?? this.taskOrder,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastRunId: lastRunId ?? this.lastRunId,
    );
  }

  static Batch fromJson(Map<String, Object?> json) {
    return Batch(
      id: json['id'] as String,
      name: json['name'] as String,
      description: (json['description'] as String?) ?? '',
      status: (json['status'] as String?) ?? BatchStatus.paused,
      controlServerId: json['control_server_id'] as String,
      managedServerIds: (json['managed_server_ids'] as List)
          .cast<String>()
          .toList(),
      taskOrder: (json['task_order'] as List).cast<String>().toList(),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      lastRunId: json['last_run_id'] as String?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'status': status,
      'control_server_id': controlServerId,
      'managed_server_ids': managedServerIds,
      'task_order': taskOrder,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'last_run_id': lastRunId,
    };
  }
}
