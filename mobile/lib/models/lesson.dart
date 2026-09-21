class Lesson {
  final int id;
  final String subject;
  final String rawSubject;
  final String teacher;
  final String room;
  final int lessonNum;
  final String startTime;
  final String endTime;
  final String rawDate;
  final int dayOfWeek;
  final String? group;
  final String lessonType;
  final String? academicYear;

  // Динамические статусы изменений из Diff Engine
  bool isCancelled;
  bool isRoomChanged;
  bool isTeacherChanged;
  bool isNew;
  String? oldRoom;
  String? oldTeacher;
  String? changeNote;

  Lesson({
    required this.id,
    required this.subject,
    required this.rawSubject,
    required this.teacher,
    required this.room,
    required this.lessonNum,
    required this.startTime,
    required this.endTime,
    required this.rawDate,
    required this.dayOfWeek,
    required this.lessonType,
    this.group,
    this.academicYear,
    this.isCancelled = false,
    this.isRoomChanged = false,
    this.isTeacherChanged = false,
    this.isNew = false,
    this.oldRoom,
    this.oldTeacher,
    this.changeNote,
  });

  static final _typeRegex = RegExp(
    r'^(лек|пр|лаб|сем|зач|экз|конс|кп|кр)[\.\s]+(.*)', 
    caseSensitive: false
  );

  factory Lesson.fromJson(Map<String, dynamic> json) {
    final originalSubject = (json['дисциплина'] as String? ?? 'Занятие').trim();
    String detectedType = 'Занятие';
    String cleanSubject = originalSubject;

    // Извлечение типа занятия из префикса названия (лек, пр, лаб и т.д.)
    final match = _typeRegex.firstMatch(originalSubject);
    if (match != null) {
      final prefix = match.group(1)!.toLowerCase();
      cleanSubject = match.group(2)!.trim();
      switch (prefix) {
        case 'лек':
          detectedType = 'Лекция';
          break;
        case 'пр':
          detectedType = 'Практика';
          break;
        case 'лаб':
          detectedType = 'Лабораторная';
          break;
        case 'сем':
          detectedType = 'Семинар';
          break;
        case 'зач':
          detectedType = 'Зачет';
          break;
        case 'экз':
          detectedType = 'Экзамен';
          break;
        case 'конс':
          detectedType = 'Консультация';
          break;
        default:
          detectedType = 'Занятие';
      }
    } else {
      final lower = originalSubject.toLowerCase();
      if (lower.contains('военная кафедра') || lower.contains('кдв')) {
        detectedType = 'Военная подготовка';
      } else if (lower.contains('проект')) {
        detectedType = 'Проект';
      } else if (lower.contains('стартап')) {
        detectedType = 'Семинар';
      }
    }

    return Lesson(
      id: json['код'] as int? ?? 0,
      subject: cleanSubject.isNotEmpty ? cleanSubject : originalSubject,
      rawSubject: originalSubject,
      teacher: (json['преподаватель'] as String? ?? 
                json['фиоПреподавателя'] as String? ?? '').trim(),
      room: (json['аудитория'] as String? ?? '').trim(),
      lessonNum: json['номерЗанятия'] as int? ?? 1,
      startTime: json['начало'] as String? ?? '',
      endTime: json['конец'] as String? ?? '',
      rawDate: json['дата'] as String? ?? '',
      dayOfWeek: json['деньНедели'] as int? ?? 1,
      lessonType: detectedType,
      group: json['группа'] as String?,
      academicYear: json['учебныйГод'] as String?,
    );
  }

  bool get isMilitaryTraining {
    final lowerSubj = rawSubject.toLowerCase();
    final lowerTeacher = teacher.toLowerCase();
    return lowerSubj.contains('военная кафедра') || lowerTeacher.contains('полковник');
  }

  Map<String, dynamic> toJson() {
    return {
      'код': id,
      'дисциплина': rawSubject,
      'преподаватель': teacher,
      'аудитория': room,
      'номерЗанятия': lessonNum,
      'начало': startTime,
      'конец': endTime,
      'дата': rawDate,
      'деньНедели': dayOfWeek,
      'типЗанятия': lessonType,
      'isCancelled': isCancelled,
      'isRoomChanged': isRoomChanged,
      'changeNote': changeNote,
    };
  }
}
