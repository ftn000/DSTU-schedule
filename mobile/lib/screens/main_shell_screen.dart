import 'package:flutter/material.dart';
import 'schedule_screen.dart';
import 'tasks_screen.dart';

class MainShellScreen extends StatefulWidget {
  final int studentId;
  final int initialIndex;

  const MainShellScreen({
    super.key,
    required this.studentId,
    this.initialIndex = 0,
  });

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen> {
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          ScheduleScreen(studentId: widget.studentId),
          TasksScreen(studentId: widget.studentId),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) {
          setState(() => _currentIndex = idx);
        },
        indicatorColor: isDark ? const Color(0xFF1E3A8A) : const Color(0xFFDBEAFE),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.calendar_today_outlined),
            selectedIcon: Icon(Icons.calendar_today_rounded, color: Color(0xFF2563EB)),
            label: 'Расписание',
          ),
          NavigationDestination(
            icon: Icon(Icons.assignment_outlined),
            selectedIcon: Icon(Icons.assignment_rounded, color: Color(0xFF2563EB)),
            label: 'Практики и задания',
          ),
        ],
      ),
    );
  }
}
