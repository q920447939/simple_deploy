class FileBindingType {
  static const String localPath = 'local_path';
  static const String controlPath = 'control_path';
  static const String localOutput = 'local_output';

  static const Set<String> values = {localPath, controlPath, localOutput};

  static bool isValid(String? value) => values.contains(value);
}

class FileBinding {
  final String type; // local_path | control_path | local_output
  final String path;
  final String? sourceTaskId;
  final String? sourceOutput;

  const FileBinding({
    required this.type,
    required this.path,
    this.sourceTaskId,
    this.sourceOutput,
  });

  FileBinding copyWith({
    String? type,
    String? path,
    String? sourceTaskId,
    String? sourceOutput,
  }) {
    return FileBinding(
      type: type ?? this.type,
      path: path ?? this.path,
      sourceTaskId: sourceTaskId ?? this.sourceTaskId,
      sourceOutput: sourceOutput ?? this.sourceOutput,
    );
  }

  bool get isLocal => type == FileBindingType.localPath;
  bool get isControl => type == FileBindingType.controlPath;
  bool get isLocalOutput => type == FileBindingType.localOutput;

  static FileBinding fromJson(Map<String, Object?> json) {
    final rawType = json['type'] as String?;
    return FileBinding(
      type: FileBindingType.isValid(rawType)
          ? rawType!
          : FileBindingType.localPath,
      path: (json['path'] as String?) ?? '',
      sourceTaskId: json['source_task_id'] as String?,
      sourceOutput: json['source_output'] as String?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'type': type,
      'path': path,
      'source_task_id': sourceTaskId,
      'source_output': sourceOutput,
    };
  }
}
