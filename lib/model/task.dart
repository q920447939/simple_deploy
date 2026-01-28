import 'file_slot.dart';

class TaskType {
  static const String localScript = 'local_script';
  static const String ansiblePlaybook = 'ansible_playbook';
}

class TaskVariable {
  final String name;
  final String description;
  final String defaultValue;
  final bool required;

  const TaskVariable({
    required this.name,
    required this.description,
    required this.defaultValue,
    required this.required,
  });

  TaskVariable copyWith({
    String? name,
    String? description,
    String? defaultValue,
    bool? required,
  }) {
    return TaskVariable(
      name: name ?? this.name,
      description: description ?? this.description,
      defaultValue: defaultValue ?? this.defaultValue,
      required: required ?? this.required,
    );
  }

  static TaskVariable fromJson(Map<String, Object?> json) {
    return TaskVariable(
      name: (json['name'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      defaultValue: (json['default'] as String?) ?? '',
      required: (json['required'] as bool?) ?? false,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      'default': defaultValue,
      'required': required,
    };
  }
}

class TaskScript {
  /// Interpreter to run the script (e.g. bash/bat).
  final String shell;
  final String content;

  const TaskScript({required this.shell, required this.content});

  TaskScript copyWith({String? shell, String? content}) {
    return TaskScript(
      shell: shell ?? this.shell,
      content: content ?? this.content,
    );
  }

  static TaskScript fromJson(Map<String, Object?> json) {
    return TaskScript(
      shell: (json['shell'] as String?) ?? 'bash',
      content: (json['content'] as String?) ?? '',
    );
  }

  Map<String, Object?> toJson() {
    return {'shell': shell, 'content': content};
  }
}

class TaskOutput {
  final String name;
  final String path;

  const TaskOutput({required this.name, required this.path});

  TaskOutput copyWith({String? name, String? path}) {
    return TaskOutput(name: name ?? this.name, path: path ?? this.path);
  }

  static TaskOutput fromJson(Map<String, Object?> json) {
    return TaskOutput(
      name: (json['name'] as String?) ?? '',
      path: (json['path'] as String?) ?? '',
    );
  }

  Map<String, Object?> toJson() {
    return {'name': name, 'path': path};
  }
}

class Task {
  final String id;
  final String name;
  final String description;
  final String type; // local_script | ansible_playbook
  final String? playbookId; // only for ansible_playbook
  final TaskScript? script; // only for local_script
  final List<FileSlot> fileSlots;
  final List<TaskVariable> variables;
  final List<TaskOutput> outputs; // only for local_script

  const Task({
    required this.id,
    required this.name,
    required this.description,
    required this.type,
    required this.playbookId,
    required this.script,
    required this.fileSlots,
    required this.variables,
    required this.outputs,
  });

  Task copyWith({
    String? name,
    String? description,
    String? type,
    String? playbookId,
    TaskScript? script,
    List<FileSlot>? fileSlots,
    List<TaskVariable>? variables,
    List<TaskOutput>? outputs,
  }) {
    return Task(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      type: type ?? this.type,
      playbookId: playbookId ?? this.playbookId,
      script: script ?? this.script,
      fileSlots: fileSlots ?? this.fileSlots,
      variables: variables ?? this.variables,
      outputs: outputs ?? this.outputs,
    );
  }

  bool get isLocalScript => type == TaskType.localScript;
  bool get isAnsiblePlaybook => type == TaskType.ansiblePlaybook;

  static Task fromJson(Map<String, Object?> json) {
    final slots =
        (json['file_slots'] as List?)?.whereType<Map>().toList() ?? const [];
    final vars =
        (json['variables'] as List?)?.whereType<Map>().toList() ?? const [];
    final outputs =
        (json['outputs'] as List?)?.whereType<Map>().toList() ?? const [];
    final rawType = (json['type'] as String?) ?? TaskType.ansiblePlaybook;
    final scriptRaw = json['script'];
    return Task(
      id: json['id'] as String,
      name: json['name'] as String,
      description: (json['description'] as String?) ?? '',
      type: rawType,
      playbookId: json['playbook_id'] as String?,
      script: scriptRaw is Map
          ? TaskScript.fromJson(scriptRaw.cast<String, Object?>())
          : null,
      fileSlots: slots
          .map((m) => FileSlot.fromJson(m.cast<String, Object?>()))
          .toList(),
      variables: vars
          .map((m) => TaskVariable.fromJson(m.cast<String, Object?>()))
          .where((v) => v.name.trim().toLowerCase() != 'python')
          .toList(),
      outputs: outputs
          .map((m) => TaskOutput.fromJson(m.cast<String, Object?>()))
          .toList(),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'type': type,
      'playbook_id': playbookId,
      'script': script?.toJson(),
      'file_slots': fileSlots.map((s) => s.toJson()).toList(),
      'variables': variables.map((v) => v.toJson()).toList(),
      'outputs': outputs.map((o) => o.toJson()).toList(),
    };
  }
}
