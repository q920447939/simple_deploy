class PlaybookMeta {
  final String id;
  final String name;
  final String description;
  final String relativePath;
  final DateTime updatedAt;

  const PlaybookMeta({
    required this.id,
    required this.name,
    required this.description,
    required this.relativePath,
    required this.updatedAt,
  });

  PlaybookMeta copyWith({
    String? name,
    String? description,
    String? relativePath,
    DateTime? updatedAt,
  }) {
    return PlaybookMeta(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      relativePath: relativePath ?? this.relativePath,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static PlaybookMeta fromJson(Map<String, Object?> json) {
    return PlaybookMeta(
      id: json['id'] as String,
      name: json['name'] as String,
      description: (json['description'] as String?) ?? '',
      relativePath: json['relative_path'] as String,
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'relative_path': relativePath,
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}
