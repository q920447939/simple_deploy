class RunInputs {
  /// task_id -> slot_name -> [local file paths]
  final Map<String, Map<String, List<String>>> fileInputs;

  /// task_id -> var_name -> value
  final Map<String, Map<String, String>> vars;

  const RunInputs({required this.fileInputs, required this.vars});

  const RunInputs.empty() : fileInputs = const {}, vars = const {};

  static RunInputs fromJson(Map<String, Object?> json) {
    Map<String, Map<String, List<String>>> fileInputs = const {};
    final rawFiles = json['file_inputs'];
    if (rawFiles is Map) {
      final out = <String, Map<String, List<String>>>{};
      for (final e in rawFiles.entries) {
        if (e.key is! String) continue;
        if (e.value is! Map) continue;
        final taskId = e.key as String;
        final slotMap = <String, List<String>>{};
        for (final se in (e.value as Map).entries) {
          if (se.key is! String) continue;
          final slot = se.key as String;
          final v = se.value;
          if (v is List) {
            slotMap[slot] = <String>[
              for (final p in v)
                if (p is String && p.trim().isNotEmpty) p.trim(),
            ];
          }
        }
        if (slotMap.isNotEmpty) out[taskId] = slotMap;
      }
      fileInputs = out;
    }

    Map<String, Map<String, String>> vars = const {};
    final rawVars = json['vars'];
    if (rawVars is Map) {
      final out = <String, Map<String, String>>{};
      for (final e in rawVars.entries) {
        if (e.key is! String) continue;
        if (e.value is! Map) continue;
        final taskId = e.key as String;
        final varMap = <String, String>{};
        for (final ve in (e.value as Map).entries) {
          if (ve.key is! String) continue;
          final k = ve.key as String;
          final v = ve.value;
          if (v == null) continue;
          varMap[k] = v.toString();
        }
        if (varMap.isNotEmpty) out[taskId] = varMap;
      }
      vars = out;
    }

    return RunInputs(fileInputs: fileInputs, vars: vars);
  }

  Map<String, Object?> toJson() {
    return {
      'file_inputs': fileInputs,
      'vars': vars,
    };
  }
}

