class AppConfig {
  static const String appName = 'ДГТУ Расписание';
  static const String appVersion = '1.4.1';
  static const int buildNumber = 7;
  static const String telegramBotUsername = 'dstu_schedule_notify_bot';

  static String get fullVersionString => 'v$appVersion (сборка $buildNumber)';
}
