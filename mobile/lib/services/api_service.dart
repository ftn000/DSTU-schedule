import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/lesson.dart';

class ScheduleResponse {
  final List<Lesson> lessons;
  final String groupName;
  final String? dateUploading;
  final String? warning;
  final bool isFromCache;

  ScheduleResponse({
    required this.lessons,
    required this.groupName,
    this.dateUploading,
    this.warning,
    required this.isFromCache,
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

  /// Проверяет существование студента в ДГТУ и возвращает название группы
  Future<String> verifyStudentId(int studentId) async {
    final res = await getSchedule(studentId, forceRefresh: true);
    if (res.lessons.isEmpty && (res.groupName.isEmpty || res.groupName == 'Группа')) {
      throw Exception('Расписание для студента с ID $studentId не найдено в базе ДГТУ');
    }
    return res.groupName;
  }

  // --- Загрузка расписания ---

  Future<ScheduleResponse> getSchedule(int studentId, {bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = _getCacheKey(studentId);

    // 1. Попытка запросить наш бэкенд (если запущен)
    try {
      final url = Uri.parse('$baseUrl/api/schedule/$studentId?force_refresh=$forceRefresh');
      final response = await http.get(url).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final decoded = json.decode(utf8.decode(response.bodyBytes));
        await prefs.setString(cacheKey, response.body);
        return _parseSchedulePayload(decoded, isFromCache: decoded['source'] == 'cache');
      }
    } catch (_) {
      // Ошибка сети или бэкенд на ПК выключен
    }

    // 2. Если локальный бэкенд недоступен (на реальном телефоне вне дома),
    // обращаемся напрямую к официальному API ДГТУ
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
    final groupName = infoBlock['group']?['name'] as String? ?? 'Группа';
    final dateUploading = payload['date_uploading'] as String? ?? infoBlock['dateUploadingRasp'] as String?;
    final warning = fallbackWarning ?? payload['warning'] as String?;

    // Извлекаем недавние изменения для маркировки отмененных пар и переносов
    final recentChanges = (payload['recent_changes'] as List<dynamic>?) ?? [];
    final cancelledLessonIds = <int>{};
    final roomChanges = <int, String>{};

    for (final ch in recentChanges) {
      final changeType = ch['change_type'] as String?;
      final lessonId = ch['lesson_id'] as int?;
      if (lessonId == null) continue;

      if (changeType == 'CANCELLED') {
        cancelledLessonIds.add(lessonId);
      } else if (changeType == 'ROOM_CHANGED') {
        roomChanges[lessonId] = ch['details'] as String? ?? 'Аудитория перенесена';
      }
    }

    // Парсим занятия и фильтруем военную кафедру
    final lessons = rawLessons
        .map((item) => Lesson.fromJson(item as Map<String, dynamic>))
        .where((lesson) => !lesson.isMilitaryTraining)
        .toList();

    // Добавляем отмененные пары, которых уже нет в основном расписании ДГТУ
    for (final ch in recentChanges) {
      final changeType = ch['change_type'] as String?;
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
          final alreadyExists = lessons.any((l) => l.id == lessonId);
          if (!alreadyExists) {
            final cancelledLesson = Lesson.fromJson(lessonMap);
            if (!cancelledLesson.isMilitaryTraining) {
              cancelledLesson.isCancelled = true;
              cancelledLesson.changeNote = ch['details'] as String? ?? 'Пара отменена';
              lessons.add(cancelledLesson);
            }
          }
        }
      }
    }

    for (final lesson in lessons) {
      if (cancelledLessonIds.contains(lesson.id)) {
        lesson.isCancelled = true;
        lesson.changeNote = 'Пара отменена';
      }
      if (roomChanges.containsKey(lesson.id)) {
        lesson.isRoomChanged = true;
        lesson.changeNote = roomChanges[lesson.id];
      }
    }

    return ScheduleResponse(
      lessons: lessons,
      groupName: groupName,
      dateUploading: dateUploading,
      warning: warning,
      isFromCache: isFromCache,
    );
  }
}
