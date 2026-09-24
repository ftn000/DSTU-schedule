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
  final String? color;

  // Динамические статусы изменений из Diff Engine
  bool isCancelled;
  bool isRoomChanged;
  bool isTeacherChanged;
  bool isTimeChanged;
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
    this.color,
    this.isCancelled = false,
    this.isRoomChanged = false,
    this.isTeacherChanged = false,
    this.isTimeChanged = false,
    this.isNew = false,
    this.oldRoom,
    this.oldTeacher,
    this.changeNote,
  });

  static final _typePrefixRegex = RegExp(
    r'^(лек|пр|лаб|сем|зач|экз|конс|кп|кр)[\.\s]+(.*)', 
    caseSensitive: false
  );

  static String detectLessonType(String originalSubject, String? theme, {String? color}) {
    final s = originalSubject.trim();
    final t = (theme ?? '').trim().toLowerCase();
    final c = (color ?? '').trim().toLowerCase();

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

    // 2. В ДГТУ в поле 'тема' (theme) часто указывается конкретный тип занятия
    if (t.contains('лекция') || t.contains('лекц') || t.contains('лек.') || t.startsWith('лек ')) {
      return 'Лекция';
    }
    if (t.contains('практика') || t.contains('практ') || t.startsWith('пр ') || t.startsWith('пр.')) {
      return 'Практика';
    }
    if (t.contains('лаборатор') || t.startsWith('лаб')) return 'Лабораторная';
    if (t.contains('семинар')) return 'Семинар';
    if (t.contains('зачет')) return 'Зачет';
    if (t.contains('экзамен')) return 'Экзамен';
    if (t.contains('защита')) return 'Защита';
    if (t.contains('консультация')) return 'Консультация';

    // 3. Анализ по системному цвету события в расписании ДГТУ:
    // В ДГТУ цвет ячейки расписания жестко привязан к типу:
    // #4caf50 (зеленый), #008000, #ab47bc — это Лекции
    // #5c6bc0 (индиго), #2196f3 (синий), #009688 — это Практики
    // #004c3e — Лабораторные
    if (c == '#4caf50' || c == '#008000' || c == '#ab47bc') {
      return 'Лекция';
    }
    if (c == '#5c6bc0' || c == '#2196f3' || c == '#009688') {
      return 'Практика';
    }
    if (c == '#004c3e') {
      return 'Лабораторная';
    }

    // 4. Анализ темы на прикладной характер
    if (t.contains('кейс') || 
        t.contains('воркшоп') || 
        t.contains('работа над') || 
        t.contains('работа с')) {
      return 'Практика';
    }

    // 5. Если в поле 'тема' указано содержательное теоретическое название лекции
    if (t.isNotEmpty && (
        t.startsWith('введение') || 
        t.startsWith('основы') || 
        t.startsWith('теория') || 
        t.startsWith('история') || 
        t.startsWith('архитектура')
    )) {
      return 'Лекция';
    }

    // 6. По умолчанию считаем практикой
    return 'Практика';
  }

  factory Lesson.fromJson(Map<String, dynamic> json) {
    final originalSubject = (json['дисциплина'] as String? ?? 'Занятие').trim();
    final rawTheme = json['тема'] as String?;
    final cleanTheme = (rawTheme != null && rawTheme.trim().isNotEmpty) ? rawTheme.trim() : null;
    final rawColor = json['цвет'] as String?;

    final detectedType = detectLessonType(originalSubject, cleanTheme, color: rawColor);

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
      color: rawColor,
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
      'цвет': color,
      'isCancelled': isCancelled,
      'isRoomChanged': isRoomChanged,
      'isTeacherChanged': isTeacherChanged,
      'isTimeChanged': isTimeChanged,
      'isNew': isNew,
      'changeNote': changeNote,
    };
  }
}
