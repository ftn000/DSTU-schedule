import 'dart:convert';
import 'dart:io' as io;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/task_item.dart';
import '../models/lesson.dart';
import 'api_service.dart';

class TasksService {
  static final TasksService _instance = TasksService._internal();
  factory TasksService() => _instance;
  TasksService._internal();

  String get _baseUrl => ApiService.baseUrl;

  String _cacheKey(String groupName, String? studentId) =>
      'cached_tasks_${groupName.toLowerCase().trim()}_${studentId ?? ''}';

  /// Загружает список заданий для группы со статусами студента
  Future<List<TaskItem>> getTasks(
    String groupName, {
    String? studentId,
    bool forceRefresh = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = _cacheKey(groupName, studentId);

    // Если нет требования форсированного обновления, пробуем кэш
    if (!forceRefresh) {
      final cachedStr = prefs.getString(cacheKey);
      if (cachedStr != null && cachedStr.isNotEmpty) {
        try {
          final List<dynamic> list = jsonDecode(cachedStr);
          return list.map((item) => TaskItem.fromJson(item as Map<String, dynamic>)).toList();
        } catch (_) {}
      }
    }

    try {
      final uri = Uri.parse('$_baseUrl/api/tasks').replace(
        queryParameters: {
          'group_name': groupName,
          if (studentId != null && studentId.isNotEmpty) 'student_id': studentId,
        },
      );

      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final List<dynamic> rawTasks = data['tasks'] ?? [];
        final tasks = rawTasks.map((item) => TaskItem.fromJson(item as Map<String, dynamic>)).toList();

        // Сохраняем в кэш
        await prefs.setString(cacheKey, jsonEncode(rawTasks));
        return tasks;
      }
    } catch (_) {
      // При ошибке сети возвращаем кэш, если он есть
      final cachedStr = prefs.getString(cacheKey);
      if (cachedStr != null && cachedStr.isNotEmpty) {
        final List<dynamic> list = jsonDecode(cachedStr);
        return list.map((item) => TaskItem.fromJson(item as Map<String, dynamic>)).toList();
      }
    }

    return [];
  }

  /// Создает или обновляет задание
  Future<int?> createOrUpdateTask(TaskItem task) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/tasks');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode({
          'task_id': task.id > 0 ? task.id : null,
          'group_name': task.groupName,
          'subject': task.subject,
          'title': task.title,
          'lesson_type': task.lessonType,
          'lesson_num': task.lessonNum,
          'lesson_date': task.lessonDate,
          'description': task.description,
          'deadline': task.deadline,
          'created_by': task.createdBy,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        return data['task_id'] as int?;
      }
    } catch (_) {}
    return null;
  }

  /// Удаляет задание
  Future<bool> deleteTask(int taskId) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/tasks/$taskId');
      final response = await http.delete(uri).timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Сохраняет или обновляет решение студента
  Future<bool> saveSubmission(
    int taskId,
    String studentId,
    TaskStatus status, {
    String? textSolution,
    String? grade,
  }) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/tasks/$taskId/submission');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode({
          'student_id': studentId,
          'status': status.code,
          'text_solution': textSolution,
          'grade': grade,
        }),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Загрузка файла (методичка или решение)
  Future<TaskFile?> uploadFile({
    required int taskId,
    required String filePath,
    required String fileName,
    required String fileType, // 'task_attachment' или 'submission_attachment'
    String? studentId,
  }) async {
    try {
      final file = io.File(filePath);
      if (!await file.exists()) return null;
      final fileBytes = await file.readAsBytes();

      final uri = Uri.parse('$_baseUrl/api/tasks/$taskId/upload').replace(
        queryParameters: {
          'filename': fileName,
          'file_type': fileType,
          if (studentId != null && studentId.isNotEmpty) 'student_id': studentId,
        },
      );

      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': fileBytes.length.toString(),
        },
        body: fileBytes,
      ).timeout(const Duration(seconds: 45));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (data['file'] != null) {
          return TaskFile.fromJson(data['file'] as Map<String, dynamic>);
        }
      }
    } catch (_) {}
    return null;
  }

  /// Удаляет файл
  Future<bool> deleteFile(int fileId) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/tasks/files/$fileId');
      final response = await http.delete(uri).timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Пакетная синхронизация расписания: автоматическое создание практик/лабораторных в БД
  Future<int> syncScheduleTasks(String groupName, List<Lesson> lessons) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/tasks/sync-schedule');
      final payload = {
        'group_name': groupName,
        'lessons': lessons.map((l) => {
          'lessonType': l.lessonType,
          'subject': l.subject,
          'theme': l.theme,
          'date': l.rawDate,
          'num': l.lessonNum,
        }).toList(),
      };

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        return data['created_count'] as int? ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  /// Формирует ссылку для скачивания файла
  String getFileDownloadUrl(int fileId) {
    return '$_baseUrl/api/tasks/files/$fileId/download';
  }
}
