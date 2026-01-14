import 'file_slot.dart';

class Task {
  final String id;
  final String name;
  final String description;
  final String playbookId;
  final List<FileSlot> fileSlots;

  const Task({
    required this.id,
    required this.name,
    required this.description,
    required this.playbookId,
    required this.fileSlots,
  });

  Task copyWith({
    String? name,
    String? description,
    String? playbookId,
    List<FileSlot>? fileSlots,
  }) {
    return Task(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      playbookId: playbookId ?? this.playbookId,
      fileSlots: fileSlots ?? this.fileSlots,
    );
  }

  static Task fromJson(Map<String, Object?> json) {
    final slots =
        (json['file_slots'] as List?)?.whereType<Map>().toList() ?? const [];
    return Task(
      id: json['id'] as String,
      name: json['name'] as String,
      description: (json['description'] as String?) ?? '',
      playbookId: json['playbook_id'] as String,
      fileSlots: slots
          .map((m) => FileSlot.fromJson(m.cast<String, Object?>()))
          .toList(),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'playbook_id': playbookId,
      'file_slots': fileSlots.map((s) => s.toJson()).toList(),
    };
  }
}
