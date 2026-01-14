class FileSlot {
  final String name;
  final bool required;
  final bool multiple;

  const FileSlot({
    required this.name,
    required this.required,
    required this.multiple,
  });

  static FileSlot fromJson(Map<String, Object?> json) {
    return FileSlot(
      name: json['name'] as String,
      required: (json['required'] as bool?) ?? false,
      multiple: (json['multiple'] as bool?) ?? false,
    );
  }

  Map<String, Object?> toJson() {
    return {'name': name, 'required': required, 'multiple': multiple};
  }
}
