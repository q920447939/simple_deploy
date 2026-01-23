import 'run_inputs.dart';

class BatchInputSnapshot {
  final String id;
  final String name;
  final DateTime createdAt;
  final RunInputs inputs;

  const BatchInputSnapshot({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.inputs,
  });

  BatchInputSnapshot copyWith({
    String? name,
    DateTime? createdAt,
    RunInputs? inputs,
  }) {
    return BatchInputSnapshot(
      id: id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      inputs: inputs ?? this.inputs,
    );
  }

  static BatchInputSnapshot fromJson(Map<String, Object?> json) {
    final rawCreatedAt = json['created_at'] as String?;
    return BatchInputSnapshot(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? '',
      createdAt: rawCreatedAt == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.tryParse(rawCreatedAt) ??
                DateTime.fromMillisecondsSinceEpoch(0),
      inputs: json['inputs'] is Map
          ? RunInputs.fromJson((json['inputs'] as Map).cast<String, Object?>())
          : const RunInputs.empty(),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'created_at': createdAt.toIso8601String(),
      'inputs': inputs.toJson(),
    };
  }
}
