import 'file_slot.dart';
import 'task.dart';

class TaskTemplate {
  final String id;
  final String name;
  final String description;
  final String type; // local_script | ansible_playbook
  final String? playbookPath;
  final String? playbookName;
  final String? playbookDescription;
  final TaskScript? script;
  final List<FileSlot> fileSlots;
  final List<TaskVariable> variables;
  final List<TaskOutput> outputs;

  const TaskTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.type,
    required this.playbookPath,
    required this.playbookName,
    required this.playbookDescription,
    required this.script,
    required this.fileSlots,
    required this.variables,
    required this.outputs,
  });

  bool get isAnsiblePlaybook => type == TaskType.ansiblePlaybook;
  bool get isLocalScript => type == TaskType.localScript;

  static TaskTemplate fromJson(Map<String, Object?> json) {
    final slots =
        (json['file_slots'] as List?)?.whereType<Map>().toList() ?? const [];
    final vars =
        (json['variables'] as List?)?.whereType<Map>().toList() ?? const [];
    final outputs =
        (json['outputs'] as List?)?.whereType<Map>().toList() ?? const [];
    final scriptRaw = json['script'];
    return TaskTemplate(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      type: (json['type'] as String?) ?? TaskType.ansiblePlaybook,
      playbookPath: json['playbook_path'] as String?,
      playbookName: json['playbook_name'] as String?,
      playbookDescription: json['playbook_description'] as String?,
      script: scriptRaw is Map
          ? TaskScript.fromJson(scriptRaw.cast<String, Object?>())
          : null,
      fileSlots: slots
          .map((m) => FileSlot.fromJson(m.cast<String, Object?>()))
          .toList(),
      variables: vars
          .map((m) => TaskVariable.fromJson(m.cast<String, Object?>()))
          .toList(),
      outputs: outputs
          .map((m) => TaskOutput.fromJson(m.cast<String, Object?>()))
          .toList(),
    );
  }
}
