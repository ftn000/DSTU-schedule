import 'dart:ui';
import 'package:flutter/material.dart';
import 'services/api_service.dart';
import 'screens/schedule_screen.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final apiService = ApiService();
  final savedId = await apiService.getSavedStudentId();

  runApp(DstuScheduleApp(initialStudentId: savedId));
}

/// Позволяет плавно листать списки мышью на Windows и в браузере (drag to scroll)
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
      };
}

class DstuScheduleApp extends StatelessWidget {
  final int? initialStudentId;

  const DstuScheduleApp({super.key, this.initialStudentId});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ДГТУ Расписание',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const AppScrollBehavior(),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E40AF), // Фирменный синий оттенок ДГТУ
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B82F6),
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
        ),
      ),
      themeMode: ThemeMode.system,
      home: initialStudentId != null
          ? ScheduleScreen(studentId: initialStudentId!)
          : const LoginScreen(),
    );
  }
}
