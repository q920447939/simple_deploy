import 'file_binding.dart';

class BatchStatus {
  static const String paused = 'paused';
  static const String running = 'running';
  static const String ended = 'ended';
}

class BatchTaskInputs {
  final Map<String, List<FileBinding>> fileInputs;
  final Map<String, String> vars;

  const BatchTaskInputs({required this.fileInputs, required this.vars});

  const BatchTaskInputs.empty() : fileInputs = const {}, vars = const {};

  BatchTaskInputs copyWith({
    Map<String, List<FileBinding>>? fileInputs,
    Map<String, String>? vars,
  }) {
    return BatchTaskInputs(
      fileInputs: fileInputs ?? this.fileInputs,
      vars: vars ?? this.vars,
    );
  }

  static BatchTaskInputs fromJson(Map<String, Object?> json) {
    Map<String, List<FileBinding>> fileInputs = const {};
    final rawFiles = json['file_inputs'];
    if (rawFiles is Map) {
      final out = <String, List<FileBinding>>{};
      for (final e in rawFiles.entries) {
        if (e.key is! String) continue;
        final slot = e.key as String;
        final v = e.value;
        if (v is! List) continue;
        final list = <FileBinding>[];
        for (final item in v) {
          if (item is! Map) continue;
          final binding = FileBinding.fromJson(item.cast<String, Object?>());
          if (binding.path.trim().isEmpty) continue;
          list.add(binding.copyWith(path: binding.path.trim()));
        }
        if (list.isNotEmpty) out[slot] = list;
      }
      fileInputs = out;
    }

    Map<String, String> vars = const {};
    final rawVars = json['vars'];
    if (rawVars is Map) {
      final out = <String, String>{};
      for (final e in rawVars.entries) {
        if (e.key is! String) continue;
        final k = e.key as String;
        final v = e.value;
        if (v == null) continue;
        out[k] = v.toString();
      }
      vars = out;
    }

    return BatchTaskInputs(fileInputs: fileInputs, vars: vars);
  }

  Map<String, Object?> toJson() {
    return {
      'file_inputs': fileInputs.map(
        (slot, bindings) =>
            MapEntry(slot, bindings.map((b) => b.toJson()).toList()),
      ),
      'vars': vars,
    };
  }

  bool get isEmpty => fileInputs.isEmpty && vars.isEmpty;
}

class BatchTaskItem {
  final String id;
  final String taskId;
  final String name;
  final bool enabled;
  final BatchTaskInputs inputs;

  const BatchTaskItem({
    required this.id,
    required this.taskId,
    required this.name,
    required this.enabled,
    required this.inputs,
  });

  BatchTaskItem copyWith({
    String? taskId,
    String? name,
    bool? enabled,
    BatchTaskInputs? inputs,
  }) {
    return BatchTaskItem(
      id: id,
      taskId: taskId ?? this.taskId,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      inputs: inputs ?? this.inputs,
    );
  }

  static BatchTaskItem fromJson(Map<String, Object?> json) {
    return BatchTaskItem(
      id: json['id'] as String,
      taskId: json['task_id'] as String,
      name: (json['name'] as String?) ?? '',
      enabled: (json['enabled'] as bool?) ?? true,
      inputs: json['inputs'] is Map
          ? BatchTaskInputs.fromJson(
              (json['inputs'] as Map).cast<String, Object?>(),
            )
          : const BatchTaskInputs.empty(),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'task_id': taskId,
      'name': name,
      'enabled': enabled,
      'inputs': inputs.toJson(),
    };
  }
}

class Batch {
  final String id;
  final String name;
  final String description;
  final String status; // paused | running | ended
  final String controlServerId;
  final List<String> managedServerIds;
  final List<String> taskOrder;
  final List<BatchTaskItem> taskItems;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? lastRunId;
  final String pythonPath;
  final int runSeq;

  const Batch({
    required this.id,
    required this.name,
    required this.description,
    required this.status,
    required this.controlServerId,
    required this.managedServerIds,
    required this.taskOrder,
    required this.taskItems,
    required this.createdAt,
    required this.updatedAt,
    required this.lastRunId,
    required this.pythonPath,
    required this.runSeq,
  });

  Batch copyWith({
    String? name,
    String? description,
    String? status,
    String? controlServerId,
    List<String>? managedServerIds,
    List<String>? taskOrder,
    List<BatchTaskItem>? taskItems,
    DateTime? updatedAt,
    String? lastRunId,
    String? pythonPath,
    int? runSeq,
  }) {
    return Batch(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      status: status ?? this.status,
      controlServerId: controlServerId ?? this.controlServerId,
      managedServerIds: managedServerIds ?? this.managedServerIds,
      taskOrder: taskOrder ?? this.taskOrder,
      taskItems: taskItems ?? this.taskItems,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastRunId: lastRunId ?? this.lastRunId,
      pythonPath: pythonPath ?? this.pythonPath,
      runSeq: runSeq ?? this.runSeq,
    );
  }

  static Batch fromJson(Map<String, Object?> json) {
    final rawOrder = (json['task_order'] as List?) ?? const [];
    final taskOrder = rawOrder.cast<String>().toList();
    final rawItems = json['task_items'];
    List<BatchTaskItem> taskItems = const [];
    if (rawItems is List) {
      taskItems = rawItems
          .whereType<Map>()
          .map((m) => BatchTaskItem.fromJson(m.cast<String, Object?>()))
          .toList();
    }
    if (taskItems.isEmpty && taskOrder.isNotEmpty) {
      taskItems = [
        for (final id in taskOrder)
          BatchTaskItem(
            id: id,
            taskId: id,
            name: '',
            enabled: true,
            inputs: const BatchTaskInputs.empty(),
          ),
      ];
    }
    final normalizedOrder = taskOrder.isEmpty && taskItems.isNotEmpty
        ? taskItems.map((i) => i.id).toList()
        : taskOrder;

    return Batch(
      id: json['id'] as String,
      name: json['name'] as String,
      description: (json['description'] as String?) ?? '',
      status: (json['status'] as String?) ?? BatchStatus.paused,
      controlServerId: json['control_server_id'] as String,
      managedServerIds: (json['managed_server_ids'] as List)
          .cast<String>()
          .toList(),
      taskOrder: normalizedOrder,
      taskItems: taskItems,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      lastRunId: json['last_run_id'] as String?,
      pythonPath: (json['python_path'] as String?) ?? '/usr/bin/python3',
      runSeq: (json['run_seq'] as num?)?.toInt() ?? 0,
    );
  }

  List<BatchTaskItem> orderedTaskItems() {
    if (taskItems.isEmpty) return const [];
    final map = {for (final item in taskItems) item.id: item};
    final ordered = <BatchTaskItem>[];
    for (final id in taskOrder) {
      final item = map[id];
      if (item != null) ordered.add(item);
    }
    if (ordered.length == taskItems.length) return ordered;
    for (final item in taskItems) {
      if (ordered.every((x) => x.id != item.id)) {
        ordered.add(item);
      }
    }
    return ordered;
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
      'task_items': taskItems.map((t) => t.toJson()).toList(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'last_run_id': lastRunId,
      'python_path': pythonPath,
      'run_seq': runSeq,
    };
  }
}
