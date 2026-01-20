class UploadProgressStatus {
  static const String running = 'running';
  static const String success = 'success';
  static const String failed = 'failed';
}

class UploadProgress {
  final String status; // running|success|failed
  final int sent;
  final int total;
  final String? message;
  final DateTime? updatedAt;

  const UploadProgress({
    required this.status,
    required this.sent,
    required this.total,
    this.message,
    this.updatedAt,
  });

  double get fraction => total <= 0 ? 0 : sent / total;

  UploadProgress copyWith({
    String? status,
    int? sent,
    int? total,
    String? message,
    DateTime? updatedAt,
  }) {
    return UploadProgress(
      status: status ?? this.status,
      sent: sent ?? this.sent,
      total: total ?? this.total,
      message: message ?? this.message,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static UploadProgress fromJson(Map<String, Object?> json) {
    return UploadProgress(
      status: (json['status'] as String?) ?? UploadProgressStatus.running,
      sent: (json['sent'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      message: json['message'] as String?,
      updatedAt: json['updated_at'] == null
          ? null
          : DateTime.tryParse(json['updated_at'] as String),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'status': status,
      'sent': sent,
      'total': total,
      'message': message,
      'updated_at': updatedAt?.toIso8601String(),
    };
  }
}
