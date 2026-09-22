import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/schedule_change.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static const String channelId = 'dstu_schedule_channel';
  static const String channelName = 'Изменения в расписании';
  static const String channelDescription =
      'Уведомления об отменах, переносах пар и сменах аудиторий в расписании ДГТУ';

  bool _isInitialized = false;

  Future<void> initialize() async {
    if (_isInitialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
    );

    await _notificationsPlugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        debugPrint('Notification clicked with payload: ${response.payload}');
      },
    );

    // Создаем канал уведомлений с высоким приоритетом на Android
    const androidChannel = AndroidNotificationChannel(
      channelId,
      channelName,
      description: channelDescription,
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );

    final androidPlugin = _notificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(androidChannel);
      // Запрашиваем разрешение на отправку уведомлений на Android 13+
      await androidPlugin.requestNotificationsPermission();
    }

    _isInitialized = true;
  }

  Future<bool> requestPermissions() async {
    final androidPlugin = _notificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      final granted = await androidPlugin.requestNotificationsPermission();
      return granted ?? false;
    }
    return true;
  }

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
    String? subText,
  }) async {
    await initialize();

    final androidPlatformChannelSpecifics = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'Изменение в расписании ДГТУ',
      subText: subText ?? 'Расписание ДГТУ',
      styleInformation: BigTextStyleInformation(body),
    );

    final details = NotificationDetails(
      android: androidPlatformChannelSpecifics,
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );

    await _notificationsPlugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  }

  Future<void> showScheduleChangeNotification(ScheduleChange change) async {
    final title = '${change.typeIconEmoji} ${change.typeLabel}: ${change.subject}';
    final body = change.humanMessage.isNotEmpty
        ? change.humanMessage
        : '${change.lessonDate}, ${change.lessonNum}-я пара: ${change.details}';

    await showNotification(
      id: change.id % 2147483647,
      title: title,
      body: body,
      payload: 'change_${change.id}',
    );
  }

  Future<void> showMultipleChangesNotification(List<ScheduleChange> changes) async {
    if (changes.isEmpty) return;

    if (changes.length == 1) {
      await showScheduleChangeNotification(changes.first);
      return;
    }

    final cancelled = changes.where((c) => c.changeType == 'CANCELLED').length;
    final roomChanged = changes.where((c) => c.changeType == 'ROOM_CHANGED').length;
    final added = changes.where((c) => c.changeType == 'ADDED' || c.changeType == 'NEW').length;

    final parts = <String>[];
    if (cancelled > 0) parts.add('отмен: $cancelled');
    if (roomChanged > 0) parts.add('смен ауд: $roomChanged');
    if (added > 0) parts.add('новых пар: $added');

    final title = '🔔 Обновление расписания (${changes.length})';
    final summaryText = parts.isNotEmpty ? parts.join(', ') : 'затронуто ${changes.length} пар';
    final body = 'Зафиксированы изменения: $summaryText. Нажмите, чтобы посмотреть подробности.';

    await showNotification(
      id: 10001,
      title: title,
      body: body,
      payload: 'changes_summary',
    );
  }

  Future<void> showTestNotification() async {
    await showNotification(
      id: 9999,
      title: '🔔 Тестовое уведомление ДГТУ',
      body: 'Системные уведомления работают! При отменах или переносах пар они будут появляться здесь в шторке со звуком и вибрацией.',
      payload: 'test_notification',
    );
  }
}
