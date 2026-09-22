class Lesson {
  final int id;
  final String subject;
  final String rawSubject;
  final String teacher;
  String room;
  final int lessonNum;
  final String startTime;
  final String endTime;
  final String rawDate;
  final int dayOfWeek;
  final String? group;
  final String lessonType;
  final String? academicYear;
  final String? theme;

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
    this.theme,
    this.isCancelled = false,
    this.isRoomChanged = false,
    this.isTeacherChanged = false,
    this.isNew = false,
    this.oldRoom,
    this.oldTeacher,
    this.changeNote,
  });

  static final _typePrefixRegex = RegExp(
    r'^(лек|пр|лаб|сем|зач|экз|конс|кп|кр)[\.\s]+(.*)', 
    caseSensitive: false
  );

  static String detectLessonType(String originalSubject, String? theme) {
    final s = originalSubject.trim();
    final t = (theme ?? '').trim().toLowerCase();
    final sLower = s.toLowerCase();

    // 1. Проверяем префикс в самом названии предмета (лек, пр, лаб и т.д.)
    final match = _typePrefixRegex.firstMatch(s);
    if (match != null) {
      final prefix = match.group(1)!.toLowerCase();
      switch (prefix) {
        case 'лек': return 'Лекция';
        case 'пр': return 'Практика';
        case 'лаб': return 'Лабораторная';
        case 'сем': return 'Семинар';
        case 'зач': return 'Зачет';
        case 'экз': return 'Экзамен';
        case 'конс': return 'Консультация';
      }
    }

    // 2. В ДГТУ на старших курсах тип занятия указывается в поле 'тема' (theme)
    if (t.contains('лекция') || t.contains('лекц') || t.contains('лек.')) {
      return 'Лекция';
    }
    if (t.contains('практика') || 
        t.contains('практ') || 
        t.contains('семинар') || 
        t.contains('кейс') || 
        t.contains('проект') || 
        t.contains('лаборатор') || 
        t.contains('воркшоп') || 
        t.contains('дизайн') || 
        t.contains('разработка') || 
        t.contains('работа над') ||
        t.contains('работа с')) {
      return 'Практика';
    }
    if (t.contains('зачет')) return 'Зачет';
    if (t.contains('экзамен')) return 'Экзамен';
    if (t.contains('защита')) return 'Защита';

    // 3. Эвристика по названию дисциплины
    if (sLower.contains('проект') || sLower.contains('разработка') || sLower.contains('документация')) {
      return 'Практика';
    }
    if (sLower.contains('экономика') || sLower.contains('стартап') || sLower.contains('маркетинг') || sLower.contains('менеджмент')) {
      return 'Лекция';
    }

    return 'Практика';
  }

  factory Lesson.fromJson(Map<String, dynamic> json) {
    final originalSubject = (json['дисциплина'] as String? ?? 'Занятие').trim();
    final rawTheme = json['тема'] as String?;
    final cleanTheme = (rawTheme != null && rawTheme.trim().isNotEmpty) ? rawTheme.trim() : null;

    final detectedType = detectLessonType(originalSubject, cleanTheme);

    // Очищаем название предмета от префиксов вроде "лек ", "пр "
    String cleanSubject = originalSubject;
    final match = _typePrefixRegex.firstMatch(originalSubject);
    if (match != null) {
      cleanSubject = match.group(2)!.trim();
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
      theme: cleanTheme,
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
      'тема': theme,
      'isCancelled': isCancelled,
      'isRoomChanged': isRoomChanged,
      'changeNote': changeNote,
    };
  }
}
