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
  // Для Android эмулятора используйте http://10.0.2.2:8000
  // Для Windows / Web / iOS симулятора: http://127.0.0.1:8000
  static const String baseUrl = 'http://127.0.0.1:8000';
  static const String cacheKey = 'cached_schedule_json';

  Future<ScheduleResponse> getSchedule(int studentId, {bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();

    // 1. Попытка запросить наш бэкенд
    try {
      final url = Uri.parse('$baseUrl/api/schedule/$studentId?force_refresh=$forceRefresh');
      final response = await http.get(url).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final decoded = json.decode(utf8.decode(response.bodyBytes));
        
        // Кэшируем успешный ответ на устройстве
        await prefs.setString(cacheKey, response.body);

        return _parseSchedulePayload(decoded, isFromCache: decoded['source'] == 'cache');
      }
    } catch (_) {
      // Ошибка сети или бэкенд выключен
    }

    // 2. Если локальный бэкенд недоступен (например, на реальном телефоне в мобильной сети),
    // обращаемся напрямую к официальному API ДГТУ
    try {
      final directUrl = Uri.parse('https://edu.donstu.ru/api/Rasp?idStudent=$studentId');
      final directResponse = await http.get(directUrl).timeout(const Duration(seconds: 10));

      if (directResponse.statusCode == 200) {
        final decoded = json.decode(utf8.decode(directResponse.bodyBytes));
        await prefs.setString(cacheKey, directResponse.body);
        return _parseSchedulePayload(
          decoded, 
          isFromCache: false,
        );
      }
    } catch (_) {
      // И сайт ДГТУ тоже не ответил
    }

    // 3. Offline-First: если сеть не ответила, читаем локальный кэш с диска телефона
    final localJson = prefs.getString(cacheKey);
    if (localJson != null) {
      final decoded = json.decode(localJson);
      return _parseSchedulePayload(
        decoded, 
        isFromCache: true, 
        fallbackWarning: 'Нет подключения к сети. Показана сохраненная копия.'
      );
    }

    throw Exception('Не удалось загрузить расписание. Проверьте интернет.');
  }

  ScheduleResponse _parseSchedulePayload(Map<String, dynamic> payload, {bool isFromCache = false, String? fallbackWarning}) {
    final dataBlock = payload['data']?['data'] ?? payload['data'] ?? {};
    final rawLessons = (dataBlock['rasp'] as List<dynamic>?) ?? [];
    final infoBlock = dataBlock['info'] as Map<String, dynamic>? ?? {};
    final groupName = infoBlock['group']?['name'] as String? ?? 'Группа';
    final dateUploading = payload['date_uploading'] as String? ?? infoBlock['dateUploadingRasp'] as String?;
    final warning = fallbackWarning ?? payload['warning'] as String?;

    // Извлекаем недавние изменения для маркировки отмененных пар
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
        roomChanges[lessonId] = ch['details'] as String? ?? '';
      }
    }

    final lessons = rawLessons
        .map((item) => Lesson.fromJson(item as Map<String, dynamic>))
        .where((lesson) => !lesson.isMilitaryTraining)
        .toList();

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
