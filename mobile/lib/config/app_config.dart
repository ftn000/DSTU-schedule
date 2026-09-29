class AppConfig {
  static const String appName = 'ДГТУ Расписание';
  static const String appVersion = '1.7.0';
  static const int buildNumber = 18;
  static const String telegramBotUsername = 'dstu_schedule_notify_bot';

  static String get fullVersionString => 'v$appVersion (сборка $buildNumber)';
}
