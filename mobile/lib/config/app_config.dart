class AppConfig {
  static const String appName = 'ДГТУ Расписание';
  static const String appVersion = '1.9.1';
  static const int buildNumber = 27;
  static const String telegramBotUsername = 'dstu_schedule_notify_bot';

  static String get fullVersionString => 'v$appVersion (сборка $buildNumber)';
}
