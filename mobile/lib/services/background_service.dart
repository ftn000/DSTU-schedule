import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'api_service.dart';
import 'notification_service.dart';

const String backgroundSyncTaskName = 'dstu_schedule_periodic_sync';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    DartPluginRegistrant.ensureInitialized();
    WidgetsFlutterBinding.ensureInitialized();

    try {
      final prefs = await SharedPreferences.getInstance();
      var studentId = prefs.getInt('saved_student_id');
      if (studentId == null) {
        studentId = 347338;
        await prefs.setInt('saved_student_id', studentId);
      }

      final now = DateTime.now().toIso8601String();
      await prefs.setString('last_background_sync_at', now);

      final apiService = ApiService();
      final notificationService = NotificationService();
      await notificationService.initialize();

      // Запрашиваем расписание с бэкенда
      final res = await apiService.getSchedule(studentId, forceRefresh: true);
      final notifiedIds = await apiService.getNotifiedChangeIds();

      // Находим изменения, о которых еще не уведомляли
      final newChanges = res.changes.where((c) => !notifiedIds.contains(c.id)).toList();
      if (newChanges.isNotEmpty) {
        if (newChanges.length == 1) {
          await notificationService.showScheduleChangeNotification(newChanges.first);
        } else {
          await notificationService.showMultipleChangesNotification(newChanges);
        }
        await apiService.markChangesAsNotified(newChanges.map((c) => c.id).toList());
      }
      return true;
    } catch (e) {
      debugPrint('Background sync error: $e');
      return true;
    }
  });
}

class BackgroundService {
  static Future<void> initialize() async {
    try {
      await Workmanager().initialize(callbackDispatcher);

      // Минимальный интервал периодического воркера в Android OS составляет 15 минут
      await Workmanager().registerPeriodicTask(
        backgroundSyncTaskName,
        'syncScheduleChangesTask',
        frequency: const Duration(minutes: 15),
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      );
    } catch (e) {
      debugPrint('BackgroundService initialize error: $e');
    }
  }
}
