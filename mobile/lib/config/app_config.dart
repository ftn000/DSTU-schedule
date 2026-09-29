class AppConfig {
  static const String appName = 'ДГТУ Расписание';
  static const String appVersion = '1.6.0';
  static const int buildNumber = 17;
  static const String telegramBotUsername = 'dstu_schedule_notify_bot';

  static String get fullVersionString => 'v$appVersion (сборка $buildNumber)';
}
