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
  String lessonType;
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

  static final _explicitLectureThemeRegex = RegExp(
    r'(?:^|[\s,.;:()])(лекция|лекц\.|лек\.)(?:$|[\s,.;:()0-9])|^тема\s*\d+',
    caseSensitive: false,
  );

  static final _explicitPracticeThemeRegex = RegExp(
    r'(?:^|[\s,.;:()])(практика|практическое|практикум|пр\.|кср)(?:$|[\s,.;:()0-9])',
    caseSensitive: false,
  );

  static String detectLessonType(String originalSubject, String? theme, {String? color}) {
    final s = originalSubject.trim();
    final sLower = s.toLowerCase();
    final t = (theme ?? '').trim().toLowerCase();
    final c = (color ?? '').trim().toLowerCase();

    // 1. Проверяем явный префикс в самом названии предмета (лек, пр, лаб и т.д.)
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

    // 2. Явное указание типа занятия в поле 'тема' (theme)
    if (_explicitLectureThemeRegex.hasMatch(t)) {
      return 'Лекция';
    }
    if (_explicitPracticeThemeRegex.hasMatch(t)) {
      return 'Практика';
    }
    if (t.contains('лаборатор') || t.startsWith('лаб')) return 'Лабораторная';
    if (t.contains('семинар')) return 'Семинар';
    if (t.startsWith('зачет') || t.startsWith('зачёт') || t == 'зачет') return 'Зачет';
    if (t.startsWith('экзамен') || t == 'экзамен') return 'Экзамен';
    if (t.startsWith('защита') || t.startsWith('предзащита') || t.startsWith('открытая защита')) return 'Защита';
    if (t.startsWith('консультация') || sLower.startsWith('консультация')) return 'Консультация';

    // 3. Профильный проект всегда является практическим занятием
    if (sLower.contains('профильный проект')) {
      return 'Практика';
    }

    // 4. Прикладные маркеры практики в названии темы занятия
    if (t.contains('работа над') ||
        t.contains('работа с') ||
        t.contains('работа по') ||
        t.contains('кейс') ||
        t.contains('воркшоп') ||
        t.contains('мастер-слайд') ||
        t.contains('мастер-класс') ||
        t.contains('плейтест') ||
        t.contains('разработка') ||
        t.contains('сборка') ||
        t.contains('моделирование') ||
        t.contains('расчет') ||
        t.contains('расчёт') ||
        t.contains('решение задач') ||
        t.contains('поиск и анализ') ||
        t.contains('пакет конкурсной')) {
      return 'Практика';
    }

    // 5. Анализ по системному цвету потока в ДГТУ / Modeus:
    // #4caf50 (зеленый), #008000 — поток лекций
    // #5c6bc0, #2196f3, #009688, #ff9800, #ab47bc, #fdd017, #44c8c8 — поток практик
    // #004c3e — лабораторные работы, #ef5350 — контрольные точки / зачеты
    if (c == '#4caf50' || c == '#008000') {
      return 'Лекция';
    }
    if (c == '#5c6bc0' ||
        c == '#2196f3' ||
        c == '#009688' ||
        c == '#ff9800' ||
        c == '#ab47bc' ||
        c == '#fdd017' ||
        c == '#44c8c8') {
      return 'Практика';
    }
    if (c == '#004c3e') {
      return 'Лабораторная';
    }
    if (c == '#ef5350') {
      return 'Зачет';
    }

    // 6. Теоретические названия лекционных тем
    if (t.isNotEmpty && (
        t.startsWith('введение') ||
        t.startsWith('основы') ||
        t.startsWith('теория') ||
        t.startsWith('история') ||
        t.startsWith('архитектура') ||
        t.startsWith('проектная документация') ||
        t.startsWith('отчеты о нир') ||
        t.startsWith('оформление научных') ||
        t.startsWith('визуализация результатов') ||
        t.startsWith('принципы') ||
        t.startsWith('методология') ||
        t.startsWith('современные тренды') ||
        t.startsWith('проблемы защиты') ||
        t.startsWith('особенности реализации') ||
        t.startsWith('обучение с подкреплением') ||
        t.startsWith('процедурная генерация')
    )) {
      return 'Лекция';
    }

    // 7. По умолчанию считаем практикой
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
