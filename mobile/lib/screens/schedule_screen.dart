import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../widgets/lesson_card.dart';
import 'login_screen.dart';

class ScheduleScreen extends StatefulWidget {
  final int studentId;

  const ScheduleScreen({super.key, this.studentId = 347338});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  final ApiService _apiService = ApiService();
  final ScrollController _dayScrollController = ScrollController();

  bool _isLoading = true;
  String? _errorMessage;
  ScheduleResponse? _scheduleData;

  late String _todayDateStr;
  late String _selectedDate;
  late List<DateTime> _twoWeeksDays;

  static const List<String> _weekdaysRu = [
    'Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'
  ];

  static const List<String> _monthsRu = [
    'янв', 'фев', 'мар', 'апр', 'май', 'июн',
    'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'
  ];

  @override
  void initState() {
    super.initState();
    _initTwoWeeksWindow();
    _loadSchedule();
  }

  @override
  void dispose() {
    _dayScrollController.dispose();
    super.dispose();
  }

  void _initTwoWeeksWindow() {
    final now = DateTime.now();
    _todayDateStr = DateFormat('yyyy-MM-dd').format(now);
    _selectedDate = _todayDateStr;

    // Понедельник текущей недели
    final currentMonday = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));

    // Окно ровно на 14 дней: текущая неделя + следующая (Пн - Вс)
    _twoWeeksDays = List.generate(14, (i) => currentMonday.add(Duration(days: i)));

    // Автопрокрутка к сегодняшнему дню после построения кадра
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final todayIndex = now.weekday - 1;
      if (todayIndex >= 0) {
        _scrollToDayIndex(todayIndex);
      }
    });
  }

  void _selectDate(DateTime dt) {
    final dateStr = DateFormat('yyyy-MM-dd').format(dt);
    if (dateStr == _selectedDate) return;

    setState(() {
      _selectedDate = dateStr;
    });

    final index = _twoWeeksDays.indexWhere(
      (d) => DateFormat('yyyy-MM-dd').format(d) == dateStr,
    );
    if (index != -1) {
      _scrollToDayIndex(index);
    }
  }

  void _goToToday() {
    final now = DateTime.now();
    _selectDate(now);
  }

  void _goToPreviousDay() {
    final currentIndex = _twoWeeksDays.indexWhere(
      (d) => DateFormat('yyyy-MM-dd').format(d) == _selectedDate,
    );
    if (currentIndex > 0) {
      _selectDate(_twoWeeksDays[currentIndex - 1]);
    }
  }

  void _goToNextDay() {
    final currentIndex = _twoWeeksDays.indexWhere(
      (d) => DateFormat('yyyy-MM-dd').format(d) == _selectedDate,
    );
    if (currentIndex != -1 && currentIndex < _twoWeeksDays.length - 1) {
      _selectDate(_twoWeeksDays[currentIndex + 1]);
    }
  }

  void _scrollToDayIndex(int index) {
    if (_dayScrollController.hasClients) {
      final screenWidth = MediaQuery.of(context).size.width;
      final targetOffset = (index * 76.0) - (screenWidth / 2) + 38.0;
      _dayScrollController.animateTo(
        targetOffset.clamp(0.0, _dayScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _loadSchedule({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final res = await _apiService.getSchedule(widget.studentId, forceRefresh: forceRefresh);
      setState(() {
        _scheduleData = res;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  Future<void> _handleSwitchStudent() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сменить студента'),
        content: Text(
          'Текущий подключенный ID: ${widget.studentId}.\nВы хотите ввести другой ID студента?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Сменить'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await _apiService.clearSavedStudentId();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _scheduleData?.groupName ?? 'Расписание ДГТУ',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (_scheduleData != null)
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _scheduleData!.isFromCache ? Colors.amber : Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _scheduleData!.isFromCache ? 'Кэш (офлайн)' : 'Актуально',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.today_rounded),
            tooltip: 'Сегодня',
            onPressed: _goToToday,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
            onPressed: () => _loadSchedule(forceRefresh: true),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Опции',
            onSelected: (value) {
              if (value == 'switch_student') {
                _handleSwitchStudent();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'switch_student',
                child: Row(
                  children: [
                    Icon(Icons.swap_horiz_rounded, size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    const Text('Сменить ID студента'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: _selectedDate != _todayDateStr
          ? FloatingActionButton.extended(
              onPressed: _goToToday,
              icon: const Icon(Icons.today_rounded),
              label: const Text('Сегодня'),
            )
          : null,
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Загрузка расписания...'),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off, size: 56, color: Colors.redAccent),
              const SizedBox(height: 16),
              Text(
                'Ошибка загрузки',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () => _loadSchedule(forceRefresh: true),
                icon: const Icon(Icons.refresh),
                label: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }

    // Фильтруем пары по выбранному дню
    final currentDayLessons = _scheduleData?.lessons.where((l) {
      return l.rawDate.startsWith(_selectedDate);
    }).toList() ?? [];

    currentDayLessons.sort((a, b) => a.lessonNum.compareTo(b.lessonNum));

    return Column(
      children: [
        // Предупреждение о сбое сайта вуза (если бэкенд отдал предупреждение)
        if (_scheduleData?.warning != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.amber.shade100,
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.amber.shade900, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _scheduleData!.warning!,
                    style: TextStyle(color: Colors.amber.shade900, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),

        // Горизонтальный селектор дней (текущая + следующая неделя)
        Container(
          height: 72,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.15)),
            ),
          ),
          child: ListView.builder(
            controller: _dayScrollController,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _twoWeeksDays.length,
            itemBuilder: (context, index) {
              final dt = _twoWeeksDays[index];
              final dateStr = DateFormat('yyyy-MM-dd').format(dt);
              final isSelected = dateStr == _selectedDate;
              final isToday = dateStr == _todayDateStr;

              final weekday = _weekdaysRu[dt.weekday - 1];
              final month = _monthsRu[dt.month - 1];
              final dayNum = dt.day;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: InkWell(
                  onTap: () => _selectDate(dt),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: 68,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : (isToday 
                              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.25)
                              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3)),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isSelected
                            ? theme.colorScheme.primary
                            : (isToday 
                                ? theme.colorScheme.primary.withValues(alpha: 0.5) 
                                : theme.dividerColor.withValues(alpha: 0.15)),
                        width: isSelected || isToday ? 1.5 : 1.0,
                      ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: theme.colorScheme.primary.withValues(alpha: 0.25),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              )
                            ]
                          : null,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          weekday,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: isSelected
                                ? Colors.white
                                : (isToday ? theme.colorScheme.primary : theme.textTheme.bodyMedium?.color),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$dayNum $month',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                            color: isSelected
                                ? Colors.white.withValues(alpha: 0.9)
                                : theme.textTheme.bodySmall?.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // Список пар на выбранный день
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (details) {
              if (details.primaryVelocity == null) return;
              if (details.primaryVelocity! < -180) {
                // Свайп влево -> следующий день
                _goToNextDay();
              } else if (details.primaryVelocity! > 180) {
                // Свайп вправо -> предыдущий день
                _goToPreviousDay();
              }
            },
            child: RefreshIndicator(
              onRefresh: () => _loadSchedule(forceRefresh: true),
              child: currentDayLessons.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.weekend_outlined, 
                              size: 64, 
                              color: theme.disabledColor.withValues(alpha: 0.5),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'На этот день пар нет 🎉',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Можно отдыхать или заняться своими делами',
                              style: TextStyle(color: theme.textTheme.bodySmall?.color),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: currentDayLessons.length,
                      itemBuilder: (context, index) {
                        return LessonCard(lesson: currentDayLessons[index]);
                      },
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
