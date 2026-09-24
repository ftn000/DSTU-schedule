import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/lesson.dart';
import '../models/schedule_change.dart';

class ScheduleResponse {
  final List<Lesson> lessons;
  final String groupName;
  final String? dateUploading;
  final String? warning;
  final bool isFromCache;
  final List<ScheduleChange> changes;

  ScheduleResponse({
    required this.lessons,
    required this.groupName,
    this.dateUploading,
    this.warning,
    required this.isFromCache,
    this.changes = const [],
  });
}

class ApiService {

  static const String baseUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  static const String _savedIdKey = 'saved_student_id';

  static String _getCacheKey(int studentId) => 'cached_schedule_json_$studentId';

  // --- Методы управления авторизацией / сохраненным студентом ---

  Future<int?> getSavedStudentId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_savedIdKey);
  }

  Future<void> saveStudentId(int studentId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_savedIdKey, studentId);
  }

  Future<void> clearSavedStudentId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_savedIdKey);
  }

  static const String _readChangeIdsKey = 'read_change_ids';

  Future<Set<int>> getReadChangeIds() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_readChangeIdsKey) ?? [];
    return list.map((e) => int.tryParse(e) ?? 0).where((e) => e > 0).toSet();
  }

  Future<void> markChangeAsRead(int changeId) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_readChangeIdsKey) ?? [];
    final set = list.toSet()..add(changeId.toString());
    await prefs.setStringList(_readChangeIdsKey, set.toList());
  }

  Future<void> markAllChangesAsRead(List<int> changeIds) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_readChangeIdsKey) ?? [];
    final set = list.toSet()..addAll(changeIds.map((e) => e.toString()));
    await prefs.setStringList(_readChangeIdsKey, set.toList());
  }

  static const String _notifiedChangeIdsKey = 'notified_change_ids';

  Future<Set<int>> getNotifiedChangeIds() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_notifiedChangeIdsKey) ?? [];
    return list.map((e) => int.tryParse(e) ?? 0).where((e) => e > 0).toSet();
  }

  Future<void> markChangesAsNotified(List<int> changeIds) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_notifiedChangeIdsKey) ?? [];
    final set = list.toSet()..addAll(changeIds.map((e) => e.toString()));
    await prefs.setStringList(_notifiedChangeIdsKey, set.toList());
  }

  /// Проверяет существование студента в ДГТУ и возвращает название группы
  Future<String> verifyStudentId(int studentId) async {
    final res = await getSchedule(studentId, forceRefresh: true);
    if (res.lessons.isEmpty && (res.groupName.isEmpty || res.groupName == 'Группа')) {
      throw Exception('Расписание для студента с ID $studentId не найдено в базе ДГТУ');
    }
    return res.groupName;
  }

  // --- Загрузка расписания ---

  /// Быстрое чтение локального кэша с телефона (для мгновенного старта до ответа сервера)
  Future<ScheduleResponse?> getCachedSchedule(int studentId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final localJson = prefs.getString(_getCacheKey(studentId));
      if (localJson != null) {
        final decoded = json.decode(localJson);
        return _parseSchedulePayload(decoded, isFromCache: true);
      }
    } catch (_) {}
    return null;
  }

  Future<ScheduleResponse> getSchedule(int studentId, {bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = _getCacheKey(studentId);

    // 1. Попытка запросить наш бэкенд-сервер
    try {
      final url = Uri.parse('$baseUrl/api/schedule/$studentId?force_refresh=$forceRefresh');
      final response = await http.get(url).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final decoded = json.decode(utf8.decode(response.bodyBytes));
        await prefs.setString(cacheKey, response.body);
        // Если сервер ответил успешно — данные актуальны (isFromCache = false),
        // кроме случая аварийного фоллбэка при падении самого сайта ДГТУ.
        final isFallback = decoded['source'] == 'cache_fallback';
        return _parseSchedulePayload(decoded, isFromCache: isFallback);
      }
    } catch (_) {
      // Ошибка сети или сервер недоступен
    }

    // 2. Если наш бэкенд недоступен, обращаемся напрямую к официальному API ДГТУ
    try {
      final directUrl = Uri.parse('https://edu.donstu.ru/api/Rasp?idStudent=$studentId');
      final directResponse = await http.get(directUrl).timeout(const Duration(seconds: 10));

      if (directResponse.statusCode == 200) {
        final decoded = json.decode(utf8.decode(directResponse.bodyBytes));
        
        // Проверка: вернул ли ДГТУ ошибку
        if (decoded is Map<String, dynamic> && decoded['state'] == -1) {
          throw Exception(decoded['msg'] ?? 'Студент не найден');
        }

        await prefs.setString(cacheKey, directResponse.body);
        return _parseSchedulePayload(
          decoded, 
          isFromCache: false,
        );
      }
    } catch (e) {
      if (e is Exception && e.toString().contains('не найден')) {
        rethrow;
      }
    }

    // 3. Offline-First: если сети нет, читаем локальный кэш с диска телефона
    final localJson = prefs.getString(cacheKey);
    if (localJson != null) {
      final decoded = json.decode(localJson);
      return _parseSchedulePayload(
        decoded, 
        isFromCache: true, 
        fallbackWarning: 'Нет подключения к сети. Показана сохраненная копия.'
      );
    }

    throw Exception('Не удалось загрузить расписание. Проверьте интернет или правильность ID студента.');
  }

  ScheduleResponse _parseSchedulePayload(Map<String, dynamic> payload, {bool isFromCache = false, String? fallbackWarning}) {
    final dataBlock = payload['data']?['data'] ?? payload['data'] ?? {};
    final rawLessons = (dataBlock['rasp'] as List<dynamic>?) ?? [];
    final infoBlock = dataBlock['info'] as Map<String, dynamic>? ?? {};
    String groupName = infoBlock['group']?['name'] as String? ?? 'Группа';

    // Интеллектуальное вычленение реальной академической группы (например, Т.РИ42, ВПР41)
    // В ДГТУ info.group.name часто 'заморожен' на 1-м курсе (напр. Т23EngСР-03),
    // а на старших курсах в расписании пишутся композитные коды вроде "Т26ВиМИ-Т.РИ42(6993)".
    final academicGroupRegex = RegExp(
      r'(?:Т\.[А-Я]{2,4}\d{2}|(?<![А-ЯA-Za-z0-9])[А-Я]{2,4}\d{2}(?![А-ЯA-Za-z0-9]))',
    );
    final groupCounts = <String, int>{};
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: 200));

    for (final item in rawLessons) {
      if (item is Map<String, dynamic>) {
        final dateStr = item['дата'] as String? ?? '';
        final dt = DateTime.tryParse(dateStr);
        if (dt != null && dt.isAfter(cutoff)) {
          final subj = (item['дисциплина'] as String? ?? '').toLowerCase();
          if (subj.contains('военная кафедра')) continue;

          final rawGroup = item['группа'] as String? ?? '';
          final matches = academicGroupRegex.allMatches(rawGroup);
          for (final m in matches) {
            final grp = m.group(0)!;
            groupCounts[grp] = (groupCounts[grp] ?? 0) + 1;
          }
        }
      }
    }

    if (groupCounts.isNotEmpty) {
      final sorted = groupCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      groupName = sorted.first.key;
    } else {
      for (final item in rawLessons.reversed) {
        if (item is Map<String, dynamic>) {
          final rawGroup = item['группа'] as String? ?? '';
          final matches = academicGroupRegex.allMatches(rawGroup);
          for (final m in matches) {
            final grp = m.group(0)!;
            groupCounts[grp] = (groupCounts[grp] ?? 0) + 1;
          }
          if (groupCounts.isNotEmpty) {
            final sorted = groupCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
            groupName = sorted.first.key;
            break;
          }
        }
      }
    }

    final dateUploading = payload['date_uploading'] as String? ?? infoBlock['dateUploadingRasp'] as String?;
    final warning = fallbackWarning ?? payload['warning'] as String?;

    // Извлекаем недавние изменения для маркировки отмененных пар, переносов и смен аудиторий
    final recentChanges = (payload['recent_changes'] as List<dynamic>?) ?? [];
    
    // Вспомогательная нормализация названий предметов
    String normSubj(String s) {
      final clean = s.trim().toLowerCase();
      final typePrefixRegex = RegExp(r'^(?:лек|пр|лаб|сем|зач|экз|конс|кп|кр)[\.\s]+', caseSensitive: false);
      return clean.replaceFirst(typePrefixRegex, '').trim();
    }

    final cancelledLessonIds = <int>{};
    final roomChangesById = <int, String>{};
    final teacherChangesById = <int, String>{};
    final timeChangesById = <int, String>{};
    final addedLessonIds = <int>{};

    for (final ch in recentChanges) {
      final changeType = (ch['change_type'] as String? ?? ch['type'] as String? ?? '').toUpperCase();
      final lessonId = ch['lesson_id'] as int?;
      final details = ch['details'] as String? ?? ch['human_message'] as String? ?? '';

      if (lessonId != null) {
        switch (changeType) {
          case 'CANCELLED':
            cancelledLessonIds.add(lessonId);
            break;
          case 'ROOM_CHANGED':
            roomChangesById[lessonId] = details.isNotEmpty ? details : 'Аудитория изменена';
            break;
          case 'TEACHER_CHANGED':
            teacherChangesById[lessonId] = details.isNotEmpty ? details : 'Преподаватель изменен';
            break;
          case 'TIME_CHANGED':
            timeChangesById[lessonId] = details.isNotEmpty ? details : 'Время изменено';
            break;
          case 'ADDED':
          case 'NEW':
            addedLessonIds.add(lessonId);
            break;
        }
      }
    }

    // Парсим занятия и фильтруем военную кафедру
    final lessons = rawLessons
        .map((item) => Lesson.fromJson(item as Map<String, dynamic>))
        .where((lesson) => !lesson.isMilitaryTraining)
        .toList();

    // Добавляем отмененные пары, которых уже нет в основном расписании ДГТУ
    for (final ch in recentChanges) {
      final changeType = (ch['change_type'] as String? ?? ch['type'] as String? ?? '').toUpperCase();
      if (changeType == 'CANCELLED') {
        final lessonId = ch['lesson_id'] as int?;
        dynamic rawData = ch['lesson_data'] ?? ch['old_lesson'];
        Map<String, dynamic>? lessonMap;
        if (rawData is Map<String, dynamic>) {
          lessonMap = rawData;
        } else if (rawData is String && rawData.isNotEmpty) {
          try {
            lessonMap = json.decode(rawData) as Map<String, dynamic>?;
          } catch (_) {}
        }

        if (lessonMap != null) {
          final cancelledLesson = Lesson.fromJson(lessonMap);
          if (!cancelledLesson.isMilitaryTraining) {
            final cancelledDate = (ch['lesson_date'] as String? ?? ch['date'] as String? ?? cancelledLesson.rawDate).split('T')[0];
            
            // Защита от дублей: если в расписании на эту же дату и номер пары УЖЕ есть активное занятие
            // по тому же предмету (например, при смене аудитории/преподавателя с новым ID),
            // ни в коем случае НЕ добавляем дубликат со статусом "отменена"!
            final alreadyCovered = lessons.any((l) =>
                (lessonId != null && l.id == lessonId) ||
                (l.rawDate.startsWith(cancelledDate) &&
                 l.lessonNum == cancelledLesson.lessonNum &&
                 normSubj(l.subject) == normSubj(cancelledLesson.subject) &&
                 !l.isCancelled)
            );

            if (!alreadyCovered) {
              cancelledLesson.isCancelled = true;
              cancelledLesson.changeNote = ch['details'] as String? ?? 'Пара отменена';
              lessons.add(cancelledLesson);
            }
          }
        }
      }
    }

    // Проставляем статусы изменений на актуальные пары
    for (final lesson in lessons) {
      if (cancelledLessonIds.contains(lesson.id)) {
        lesson.isCancelled = true;
        lesson.changeNote = 'Пара отменена';
      }
      if (roomChangesById.containsKey(lesson.id)) {
        lesson.isRoomChanged = true;
        lesson.changeNote = roomChangesById[lesson.id];
      }
      if (teacherChangesById.containsKey(lesson.id)) {
        lesson.isTeacherChanged = true;
        lesson.changeNote = teacherChangesById[lesson.id];
      }
      if (timeChangesById.containsKey(lesson.id)) {
        lesson.isTimeChanged = true;
        lesson.changeNote = timeChangesById[lesson.id];
      }
      if (addedLessonIds.contains(lesson.id)) {
        lesson.isNew = true;
      }
    }

    // Если пара не сопоставилась по ID (в ДГТУ сменился 'код'), сопоставляем по реквизитам
    for (final ch in recentChanges) {
      final changeType = (ch['change_type'] as String? ?? ch['type'] as String? ?? '').toUpperCase();
      final chDate = (ch['lesson_date'] as String? ?? ch['date'] as String? ?? '').split('T')[0];
      final chNum = ch['lesson_num'] as int? ?? 0;
      final chSubj = normSubj(ch['subject'] as String? ?? '');
      final details = ch['details'] as String? ?? ch['human_message'] as String? ?? '';

      if (chDate.isEmpty || chNum == 0 || chSubj.isEmpty) continue;

      for (final lesson in lessons) {
        if (lesson.isCancelled) continue;
        if (lesson.rawDate.startsWith(chDate) && lesson.lessonNum == chNum && normSubj(lesson.subject) == chSubj) {
          if (changeType == 'ROOM_CHANGED' && !lesson.isRoomChanged) {
            lesson.isRoomChanged = true;
            lesson.changeNote = details.isNotEmpty ? details : 'Аудитория изменена';
          } else if (changeType == 'TEACHER_CHANGED' && !lesson.isTeacherChanged) {
            lesson.isTeacherChanged = true;
            lesson.changeNote = details.isNotEmpty ? details : 'Преподаватель изменен';
          } else if (changeType == 'TIME_CHANGED' && !lesson.isTimeChanged) {
            lesson.isTimeChanged = true;
            lesson.changeNote = details.isNotEmpty ? details : 'Время изменено';
          }
        }
      }
    }

    final parsedChanges = recentChanges
        .map((ch) => ScheduleChange.fromJson(ch as Map<String, dynamic>))
        .toList();

    _refineLessonTypesByStreamContext(lessons);

    return ScheduleResponse(
      lessons: lessons,
      groupName: groupName,
      dateUploading: dateUploading,
      warning: warning,
      isFromCache: isFromCache,
      changes: parsedChanges,
    );
  }

  /// Контекстное уточнение типов занятий (Лекция / Практика) по структуре потоков дисциплины:
  /// 1. Если в один день по одному предмету стоят 2 пары подряд с одной и той же темой/цветом
  ///    (и в теме нет явного слова «Лекция»), это сдвоенный практический блок -> Практика.
  /// 2. Если у дисциплины в семестре ровно 2 основных цвета потоков, и один из них является
  ///    практическим (сдвоенные пары / повтор тем), а второй — одиночные пары с уникальными темами,
  ///    то второй цвет маркируется как Лекция.
  void _refineLessonTypesByStreamContext(List<Lesson> lessons) {
    final active = lessons.where((l) => !l.isCancelled).toList();

    // 1. Сдвоенные пары в один день с одинаковой темой и цветом -> Практика
    final byDayAndSubj = <String, List<Lesson>>{};
    for (final l in active) {
      final dateKey = l.rawDate.split('T')[0];
      final key = '${dateKey}_${l.subject.toLowerCase()}';
      byDayAndSubj.putIfAbsent(key, () => []).add(l);
    }

    final practiceStreamColorsBySubj = <String, Set<String>>{};
    for (final group in byDayAndSubj.values) {
      if (group.length >= 2) {
        final first = group.first;
        final sameTheme = group.every((l) => (l.theme ?? '') == (first.theme ?? ''));
        final sameColor = group.every((l) => (l.color ?? '') == (first.color ?? ''));
        final themeLower = (first.theme ?? '').toLowerCase();
        final isExplicitLecture = themeLower.contains('лекция') || themeLower.contains('лек.');
        if (sameTheme && sameColor && !isExplicitLecture) {
          for (final l in group) {
            if (l.lessonType == 'Лекция') {
              l.lessonType = 'Практика';
            }
          }
          final subjKey = '${first.academicYear ?? ''}_${first.subject.toLowerCase()}';
          final col = (first.color ?? '').toLowerCase();
          if (col.isNotEmpty) {
            practiceStreamColorsBySubj.putIfAbsent(subjKey, () => {}).add(col);
          }
        }
      }
    }

    // 2. Анализ парных потоков (цвет лекций vs цвет практик) внутри одной дисциплины семестра
    final bySemSubj = <String, List<Lesson>>{};
    for (final l in active) {
      final subjKey = '${l.academicYear ?? ''}_${l.subject.toLowerCase()}';
      bySemSubj.putIfAbsent(subjKey, () => []).add(l);
    }

    for (final entry in bySemSubj.entries) {
      final subjKey = entry.key;
      final subjLessons = entry.value;
      if (subjLessons.first.subject.toLowerCase().contains('профильный проект')) continue;

      final byColor = <String, List<Lesson>>{};
      for (final l in subjLessons) {
        final col = (l.color ?? '').toLowerCase();
        if (col.isEmpty || col == '#ef5350' || col == '#004c3e') continue;
        byColor.putIfAbsent(col, () => []).add(l);
      }

      if (byColor.length == 2) {
        final colors = byColor.keys.toList();
        final c1 = colors[0];
        final c2 = colors[1];
        final knownPrac = practiceStreamColorsBySubj[subjKey] ?? {};

        String? pracColor;
        String? lecColor;
        if (knownPrac.contains(c1) && !knownPrac.contains(c2)) {
          pracColor = c1;
          lecColor = c2;
        } else if (knownPrac.contains(c2) && !knownPrac.contains(c1)) {
          pracColor = c2;
          lecColor = c1;
        }

        if (pracColor != null && lecColor != null) {
          for (final l in byColor[pracColor]!) {
            final tLow = (l.theme ?? '').toLowerCase();
            if (!tLow.contains('лекция')) {
              l.lessonType = 'Практика';
            }
          }
          for (final l in byColor[lecColor]!) {
            final tLow = (l.theme ?? '').toLowerCase();
            if (!tLow.contains('практика') && !tLow.contains('работа над')) {
              l.lessonType = 'Лекция';
            }
          }
        }
      }
    }
  }
}
