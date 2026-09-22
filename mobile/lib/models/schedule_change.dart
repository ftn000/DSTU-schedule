class ScheduleChange {
  final int id;
  final String changeType; // CANCELLED, ROOM_CHANGED, TEACHER_CHANGED, ADDED, MODIFIED
  final int? lessonId;
  final String lessonDate; // YYYY-MM-DD
  final int lessonNum;
  final String subject;
  final String details;
  final String humanMessage;
  final String detectedAt;
  bool isRead;

  ScheduleChange({
    required this.id,
    required this.changeType,
    this.lessonId,
    required this.lessonDate,
    required this.lessonNum,
    required this.subject,
    required this.details,
    required this.humanMessage,
    required this.detectedAt,
    this.isRead = false,
  });

  factory ScheduleChange.fromJson(Map<String, dynamic> json) {
    return ScheduleChange(
      id: json['id'] as int? ?? (json['lesson_id'] as int? ?? DateTime.now().millisecondsSinceEpoch % 100000),
      changeType: (json['change_type'] as String? ?? json['type'] as String? ?? 'MODIFIED').toUpperCase(),
      lessonId: json['lesson_id'] as int?,
      lessonDate: (json['lesson_date'] as String? ?? json['date'] as String? ?? '').split('T')[0],
      lessonNum: json['lesson_num'] as int? ?? 1,
      subject: json['subject'] as String? ?? 'Занятие',
      details: json['details'] as String? ?? '',
      humanMessage: json['human_message'] as String? ?? '',
      detectedAt: json['detected_at'] as String? ?? DateTime.now().toIso8601String(),
      isRead: json['is_read'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'change_type': changeType,
      'lesson_id': lessonId,
      'lesson_date': lessonDate,
      'lesson_num': lessonNum,
      'subject': subject,
      'details': details,
      'human_message': humanMessage,
      'detected_at': detectedAt,
      'is_read': isRead,
    };
  }

  String get typeLabel {
    switch (changeType) {
      case 'CANCELLED':
        return 'Пара отменена';
      case 'ROOM_CHANGED':
        return 'Аудитория изменена';
      case 'TEACHER_CHANGED':
        return 'Преподаватель изменен';
      case 'ADDED':
      case 'NEW':
        return 'Пара добавлена';
      default:
        return 'Изменение пары';
    }
  }

  String get typeIconEmoji {
    switch (changeType) {
      case 'CANCELLED':
        return '🚫';
      case 'ROOM_CHANGED':
        return '⚠️';
      case 'TEACHER_CHANGED':
        return '👤';
      case 'ADDED':
      case 'NEW':
        return '➕';
      default:
        return 'ℹ️';
    }
  }
}
