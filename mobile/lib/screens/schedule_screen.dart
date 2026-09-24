import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../config/app_config.dart';
import '../models/lesson.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../widgets/lesson_card.dart';
import 'package:url_launcher/url_launcher.dart';
import 'login_screen.dart';

class ScheduleScreen extends StatefulWidget {
  final int studentId;

  const ScheduleScreen({super.key, this.studentId = 347338});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  final ApiService _apiService = ApiService();
  final NotificationService _notificationService = NotificationService();
  final ScrollController _dayScrollController = ScrollController();

  bool _isLoading = true;
  String? _errorMessage;
  ScheduleResponse? _scheduleData;

  late String _todayDateStr;
  late String _selectedDate;
  late List<DateTime> _twoWeeksDays;

  bool _isWeeklyView = false;
  int _selectedWeekIndex = 0; // 0: текущая неделя, 1: следующая неделя

  Set<int> _readChangeIds = {};

  int get _unreadChangesCount {
    if (_scheduleData == null) return 0;
    return _scheduleData!.changes.where((c) => !_readChangeIds.contains(c.id)).length;
  }

  static const List<String> _weekdaysRu = [
    'Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'
  ];

  static const List<String> _weekdaysFullRu = [
    'Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье'
  ];

  static const List<String> _monthsRu = [
    'янв', 'фев', 'мар', 'апр', 'май', 'июн',
    'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'
  ];

  static const List<String> _monthsGenitiveRu = [
    'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
    'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'
  ];

  @override
  void initState() {
    super.initState();
    _initTwoWeeksWindow();
    _apiService.saveStudentId(widget.studentId);
    _loadSchedule(forceRefresh: true);
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

  void _toggleViewMode() {
    setState(() {
      _isWeeklyView = !_isWeeklyView;
      if (_isWeeklyView) {
        // Определяем, в какой неделе находится выбранная дата
        final index = _twoWeeksDays.indexWhere(
          (d) => DateFormat('yyyy-MM-dd').format(d) == _selectedDate,
        );
        _selectedWeekIndex = (index >= 7) ? 1 : 0;
      }
    });
  }

  void _goToPreviousWeek() {
    if (_selectedWeekIndex > 0) {
      setState(() {
        _selectedWeekIndex = 0;
      });
    }
  }

  void _goToNextWeek() {
    if (_selectedWeekIndex < 1) {
      setState(() {
        _selectedWeekIndex = 1;
      });
    }
  }

  void _switchToDayFromWeek(DateTime dt) {
    _selectDate(dt);
    setState(() {
      _isWeeklyView = false;
    });
  }

  Future<void> _loadSchedule({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final res = await _apiService.getSchedule(widget.studentId, forceRefresh: forceRefresh);
      final readIds = await _apiService.getReadChangeIds();
      final notifiedIds = await _apiService.getNotifiedChangeIds();

      // Проверяем новые изменения, о которых еще не было системного уведомления в шторке
      final newUnnotified = res.changes.where((c) => !notifiedIds.contains(c.id)).toList();
      if (newUnnotified.isNotEmpty) {
        if (newUnnotified.length == 1) {
          await _notificationService.showScheduleChangeNotification(newUnnotified.first);
        } else {
          await _notificationService.showMultipleChangesNotification(newUnnotified);
        }
        await _apiService.markChangesAsNotified(newUnnotified.map((c) => c.id).toList());
      }

      if (mounted) {
        final previousUnread = _unreadChangesCount;
        setState(() {
          _scheduleData = res;
          _readChangeIds = readIds;
          _isLoading = false;
        });

        if (forceRefresh && _unreadChangesCount > previousUnread && _unreadChangesCount > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('🔔 Обнаружено изменений в расписании: $_unreadChangesCount'),
              action: SnackBarAction(
                label: 'Посмотреть',
                onPressed: _showNotificationsSheet,
              ),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceAll('Exception: ', '');
          _isLoading = false;
        });
      }
    }
  }

  void _showNotificationsSheet() {
    final theme = Theme.of(context);
    final changes = _scheduleData?.changes ?? [];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final unreadInModal = changes.where((c) => !_readChangeIds.contains(c.id)).length;

            return Container(
              height: MediaQuery.of(context).size.height * 0.75,
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    // Handle
                    const SizedBox(height: 12),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.dividerColor.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Header
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          Icon(Icons.notifications_active_rounded, color: theme.colorScheme.primary, size: 24),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Уведомления об изменениях',
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                            ),
                          ),
                          if (unreadInModal > 0)
                            TextButton(
                              onPressed: () async {
                                final allIds = changes.map((c) => c.id).toList();
                                await _apiService.markAllChangesAsRead(allIds);
                                setState(() {
                                  _readChangeIds.addAll(allIds);
                                });
                                setModalState(() {});
                              },
                              child: const Text('Прочитать все', style: TextStyle(fontSize: 12)),
                            ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),

                    // Content
                    Expanded(
                      child: changes.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.notifications_none_rounded,
                                      size: 56,
                                      color: theme.disabledColor.withValues(alpha: 0.5),
                                    ),
                                    const SizedBox(height: 16),
                                    const Text(
                                      'Изменений в расписании нет',
                                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Когда сайт ДГТУ перенесет пару, сменит аудиторию или отменит занятие, уведомление появится здесь.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: theme.textTheme.bodySmall?.color,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.all(16),
                              itemCount: changes.length,
                              itemBuilder: (context, index) {
                                final ch = changes[index];
                                final isRead = _readChangeIds.contains(ch.id);

                                Color badgeColor;
                                switch (ch.changeType) {
                                  case 'CANCELLED':
                                    badgeColor = Colors.redAccent;
                                    break;
                                  case 'ROOM_CHANGED':
                                    badgeColor = Colors.amber.shade800;
                                    break;
                                  case 'ADDED':
                                  case 'NEW':
                                    badgeColor = Colors.green.shade700;
                                    break;
                                  case 'TEACHER_CHANGED':
                                    badgeColor = Colors.purple.shade600;
                                    break;
                                  default:
                                    badgeColor = theme.colorScheme.primary;
                                }

                                return Card(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    side: BorderSide(
                                      color: isRead
                                          ? theme.dividerColor.withValues(alpha: 0.1)
                                          : badgeColor.withValues(alpha: 0.5),
                                      width: isRead ? 1.0 : 1.5,
                                    ),
                                  ),
                                  color: isRead
                                      ? theme.colorScheme.surface
                                      : badgeColor.withValues(alpha: 0.04),
                                  child: InkWell(
                                    onTap: () async {
                                      if (!isRead) {
                                        await _apiService.markChangeAsRead(ch.id);
                                        setState(() {
                                          _readChangeIds.add(ch.id);
                                        });
                                        setModalState(() {});
                                      }
                                    },
                                    borderRadius: BorderRadius.circular(14),
                                    child: Padding(
                                      padding: const EdgeInsets.all(14),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: badgeColor.withValues(alpha: 0.12),
                                                  borderRadius: BorderRadius.circular(6),
                                                  border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Text(ch.typeIconEmoji, style: const TextStyle(fontSize: 12)),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      ch.typeLabel.toUpperCase(),
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        fontWeight: FontWeight.bold,
                                                        color: badgeColor,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const Spacer(),
                                              if (!isRead)
                                                Container(
                                                  width: 8,
                                                  height: 8,
                                                  decoration: BoxDecoration(
                                                    color: badgeColor,
                                                    shape: BoxShape.circle,
                                                  ),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            ch.subject,
                                            style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            ch.humanMessage.isNotEmpty
                                                ? ch.humanMessage
                                                : '${ch.lessonDate}, ${ch.lessonNum}-я пара: ${ch.details}',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.85),
                                            ),
                                          ),
                                          const SizedBox(height: 10),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                'Дата пары: ${ch.lessonDate}',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: theme.textTheme.bodySmall?.color,
                                                ),
                                              ),
                                              TextButton.icon(
                                                onPressed: () {
                                                  Navigator.pop(ctx);
                                                  final dt = DateTime.tryParse(ch.lessonDate);
                                                  if (dt != null) {
                                                    _switchToDayFromWeek(dt);
                                                  }
                                                },
                                                icon: const Icon(Icons.arrow_forward_rounded, size: 14),
                                                label: const Text('В расписание', style: TextStyle(fontSize: 12)),
                                                style: TextButton.styleFrom(
                                                  padding: EdgeInsets.zero,
                                                  minimumSize: Size.zero,
                                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                        border: Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.15))),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _openTelegramBot,
                              icon: const Icon(Icons.send_rounded, size: 18, color: Colors.white),
                              label: const Text(
                                'Подключить Telegram-уведомления',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF229ED9),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                elevation: 0,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                await _notificationService.showTestNotification();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('🔔 Тестовое уведомление отправлено в шторку Android! Проверьте верхнюю панель.'),
                                      behavior: SnackBarBehavior.floating,
                                      duration: Duration(seconds: 3),
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(Icons.notifications_active_outlined, size: 18),
                              label: const Text('Тест уведомления в шторку Android', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openTelegramBot() async {
    const botUsername = AppConfig.telegramBotUsername;
    final url = Uri.parse('https://t.me/$botUsername?start=${widget.studentId}');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(url, mode: LaunchMode.platformDefault);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть Telegram: $e')),
        );
      }
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

  void _showAboutAppDialog() {
    showAboutDialog(
      context: context,
      applicationName: AppConfig.appName,
      applicationVersion: AppConfig.fullVersionString,
      applicationIcon: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          Icons.school_rounded,
          color: Theme.of(context).colorScheme.primary,
          size: 28,
        ),
      ),
      children: [
        const SizedBox(height: 12),
        Text('ID студента: ${widget.studentId}'),
        if (_scheduleData != null)
          Text('Группа: ${_scheduleData!.groupName}'),
        const SizedBox(height: 8),
        const Text(
          'Быстрое и удобное расписание ДГТУ с офлайн-кэшем, отслеживанием изменений и календарем.',
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            _isWeeklyView ? Icons.view_day_rounded : Icons.calendar_view_week_rounded,
          ),
          tooltip: _isWeeklyView ? 'Дневной режим' : 'Недельное расписание',
          onPressed: _toggleViewMode,
        ),
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
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_outlined),
                tooltip: 'Уведомления об изменениях',
                onPressed: _showNotificationsSheet,
              ),
              if (_unreadChangesCount > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      '$_unreadChangesCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
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
              } else if (value == 'about') {
                _showAboutAppDialog();
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
              PopupMenuItem(
                value: 'about',
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded, size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    const Text('О приложении'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: (!_isWeeklyView && _selectedDate != _todayDateStr)
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

    return _isWeeklyView ? _buildWeeklyView(theme) : _buildDailyView(theme);
  }

  Widget _buildDailyView(ThemeData theme) {
    // Фильтруем пары по выбранному дню
    final currentDayLessons = _scheduleData?.lessons.where((l) {
      return l.rawDate.startsWith(_selectedDate);
    }).toList() ?? [];

    currentDayLessons.sort((a, b) {
      final numCmp = a.lessonNum.compareTo(b.lessonNum);
      if (numCmp != 0) return numCmp;
      if (a.isCancelled != b.isCancelled) {
        return a.isCancelled ? -1 : 1; // отмененная пара всегда идет первой (слева)
      }
      return a.id.compareTo(b.id);
    });

    // Группируем пары по временному слоту (номеру пары)
    final Map<int, List<Lesson>> slotGroups = {};
    for (final l in currentDayLessons) {
      slotGroups.putIfAbsent(l.lessonNum, () => []).add(l);
    }
    final sortedSlots = slotGroups.keys.toList()..sort();

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
              child: sortedSlots.isEmpty
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
                      itemCount: sortedSlots.length,
                      itemBuilder: (context, index) {
                        final slotNum = sortedSlots[index];
                        final slotLessons = slotGroups[slotNum]!;

                        // Одиночная пара в слоте -> полноразмерная карточка
                        if (slotLessons.length == 1) {
                          return LessonCard(lesson: slotLessons.first);
                        }

                        // Две пары в одном слоте (например, одна отменена, а вторая добавлена)
                        // Делим ячейку пары пополам и размещаем 2 карточки рядом!
                        if (slotLessons.length == 2) {
                          final hasCancelled = slotLessons.any((l) => l.isCancelled);
                          final first = slotLessons.first;

                          return Container(
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: hasCancelled 
                                    ? Colors.redAccent.withValues(alpha: 0.3)
                                    : theme.dividerColor.withValues(alpha: 0.25),
                                width: 1.0,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.02),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                )
                              ],
                            ),
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: hasCancelled
                                            ? Colors.redAccent.withValues(alpha: 0.12)
                                            : theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        '${first.lessonNum} ПАРА • ${first.startTime} - ${first.endTime}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: hasCancelled ? Colors.redAccent : theme.colorScheme.primary,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      hasCancelled ? 'Замена в слоте' : '2 подгруппы',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontStyle: FontStyle.italic,
                                        color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: LessonCard(lesson: slotLessons[0], isSplit: true),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: LessonCard(lesson: slotLessons[1], isSplit: true),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        }

                        // Если больше 2 пар (редкий случай нескольких подгрупп)
                        return Column(
                          children: slotLessons.map((l) => LessonCard(lesson: l)).toList(),
                        );
                      },
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWeeklyView(ThemeData theme) {
    final weekDays = _selectedWeekIndex == 0
        ? _twoWeeksDays.sublist(0, 7)
        : _twoWeeksDays.sublist(7, 14);

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

        // Селектор текущая / следующая неделя
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.12)),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: _goToPreviousWeek,
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: _selectedWeekIndex == 0
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _selectedWeekIndex == 0
                            ? theme.colorScheme.primary.withValues(alpha: 0.5)
                            : Colors.transparent,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'Текущая неделя',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: _selectedWeekIndex == 0 ? FontWeight.bold : FontWeight.w500,
                            color: _selectedWeekIndex == 0
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.textTheme.bodyMedium?.color,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_twoWeeksDays[0].day} ${_monthsRu[_twoWeeksDays[0].month - 1]} – ${_twoWeeksDays[6].day} ${_monthsRu[_twoWeeksDays[6].month - 1]}',
                          style: TextStyle(
                            fontSize: 11,
                            color: _selectedWeekIndex == 0
                                ? theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.8)
                                : theme.textTheme.bodySmall?.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: _goToNextWeek,
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: _selectedWeekIndex == 1
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _selectedWeekIndex == 1
                            ? theme.colorScheme.primary.withValues(alpha: 0.5)
                            : Colors.transparent,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'Следующая неделя',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: _selectedWeekIndex == 1 ? FontWeight.bold : FontWeight.w500,
                            color: _selectedWeekIndex == 1
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.textTheme.bodyMedium?.color,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_twoWeeksDays[7].day} ${_monthsRu[_twoWeeksDays[7].month - 1]} – ${_twoWeeksDays[13].day} ${_monthsRu[_twoWeeksDays[13].month - 1]}',
                          style: TextStyle(
                            fontSize: 11,
                            color: _selectedWeekIndex == 1
                                ? theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.8)
                                : theme.textTheme.bodySmall?.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // Календарная сетка: дни недели слева направо в горизонтальном скролле
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return RefreshIndicator(
                onRefresh: () => _loadSchedule(forceRefresh: true),
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                      minWidth: constraints.maxWidth,
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                      child: Container(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight > 24 ? constraints.maxHeight - 24 : 0,
                        ),
                        color: Colors.transparent,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: weekDays.map((dt) {
                            final dateStr = DateFormat('yyyy-MM-dd').format(dt);
                            final isToday = dateStr == _todayDateStr;
                            final dayLessons = _scheduleData?.lessons.where((l) {
                              return l.rawDate.startsWith(dateStr);
                            }).toList() ?? [];
                            dayLessons.sort((a, b) => a.lessonNum.compareTo(b.lessonNum));

                            return _buildCalendarDayColumn(
                              theme,
                              dt,
                              dateStr,
                              isToday,
                              dayLessons,
                              minColumnHeight: constraints.maxHeight > 48 ? constraints.maxHeight - 48 : 0,
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCalendarDayColumn(
    ThemeData theme,
    DateTime dt,
    String dateStr,
    bool isToday,
    List<Lesson> dayLessons, {
    double minColumnHeight = 0,
  }) {
    final weekday = _weekdaysRu[dt.weekday - 1];
    final month = _monthsRu[dt.month - 1];
    final isSunday = dt.weekday == DateTime.sunday;

    return Container(
      width: 120,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      constraints: BoxConstraints(minHeight: minColumnHeight),
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Заголовок дня недели
          InkWell(
            onTap: () => _switchToDayFromWeek(dt),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
              decoration: BoxDecoration(
                color: isToday
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isToday
                      ? theme.colorScheme.primary
                      : theme.dividerColor.withValues(alpha: 0.15),
                  width: isToday ? 1.5 : 1.0,
                ),
                boxShadow: isToday
                    ? [
                        BoxShadow(
                          color: theme.colorScheme.primary.withValues(alpha: 0.25),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        weekday,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: isToday
                              ? Colors.white
                              : (isSunday ? Colors.redAccent : theme.textTheme.bodyMedium?.color),
                        ),
                      ),
                      if (isToday) ...[
                        const SizedBox(width: 4),
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: Colors.amberAccent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${dt.day} $month',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: isToday ? FontWeight.w600 : FontWeight.normal,
                      color: isToday
                          ? Colors.white.withValues(alpha: 0.9)
                          : theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),

          // Список пар на этот день
          if (dayLessons.isNotEmpty)
            ...dayLessons.map(
              (lesson) => _buildCalendarCompactLessonCard(theme, lesson, dt),
            )
          else
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: theme.dividerColor.withValues(alpha: 0.08),
                ),
              ),
              child: Column(
                children: [
                  Icon(
                    isSunday ? Icons.wb_sunny_outlined : Icons.event_available_outlined,
                    size: 20,
                    color: theme.disabledColor.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isSunday ? 'Выходной' : 'Пар нет',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCalendarCompactLessonCard(
    ThemeData theme,
    Lesson lesson,
    DateTime dt,
  ) {
    final typeColor = _getLessonTypeColor(lesson.lessonType);
    final isCancelled = lesson.isCancelled;
    final isRoomChanged = lesson.isRoomChanged;
    final isTeacherChanged = lesson.isTeacherChanged;
    final isTimeChanged = lesson.isTimeChanged;
    final isNew = lesson.isNew;

    Color accentColor;
    Color cardBgColor;
    if (isCancelled) {
      accentColor = Colors.redAccent;
      cardBgColor = Colors.redAccent.withValues(alpha: 0.06);
    } else if (isNew) {
      accentColor = Colors.green.shade600;
      cardBgColor = Colors.green.withValues(alpha: 0.06);
    } else if (isRoomChanged) {
      accentColor = Colors.amber.shade700;
      cardBgColor = Colors.amber.withValues(alpha: 0.08);
    } else if (isTeacherChanged) {
      accentColor = Colors.purple.shade600;
      cardBgColor = Colors.purple.withValues(alpha: 0.06);
    } else if (isTimeChanged) {
      accentColor = Colors.teal.shade600;
      cardBgColor = Colors.teal.withValues(alpha: 0.06);
    } else {
      accentColor = typeColor;
      cardBgColor = theme.colorScheme.surface;
    }

    final hasChange = isRoomChanged || isTeacherChanged || isTimeChanged || isNew;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _showLessonDetailModal(context, lesson, dt),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            decoration: BoxDecoration(
              color: cardBgColor,
              borderRadius: BorderRadius.circular(10),
              border: Border(
                left: BorderSide(color: accentColor, width: 3.5),
                top: BorderSide(
                  color: hasChange
                      ? accentColor.withValues(alpha: 0.6)
                      : theme.dividerColor.withValues(alpha: 0.18),
                ),
                right: BorderSide(
                  color: hasChange
                      ? accentColor.withValues(alpha: 0.6)
                      : theme.dividerColor.withValues(alpha: 0.18),
                ),
                bottom: BorderSide(
                  color: hasChange
                      ? accentColor.withValues(alpha: 0.6)
                      : theme.dividerColor.withValues(alpha: 0.18),
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Номер пары и время начала
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${lesson.lessonNum}п • ${lesson.startTime}',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        color: accentColor,
                      ),
                    ),
                    if (isCancelled)
                      const Text('🚫', style: TextStyle(fontSize: 10))
                    else if (isNew)
                      const Text('➕', style: TextStyle(fontSize: 10))
                    else if (isRoomChanged)
                      const Text('📍', style: TextStyle(fontSize: 10))
                    else if (isTeacherChanged)
                      const Text('👤', style: TextStyle(fontSize: 10))
                    else if (isTimeChanged)
                      const Text('⏰', style: TextStyle(fontSize: 10)),
                  ],
                ),
                const SizedBox(height: 4),

                // Название дисциплины (с многоточием)
                Text(
                  lesson.subject,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    decoration: isCancelled ? TextDecoration.lineThrough : null,
                    color: isCancelled
                        ? theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6)
                        : theme.textTheme.bodyMedium?.color,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 5),

                // Аудитория
                Row(
                  children: [
                    Icon(
                      Icons.place_outlined,
                      size: 11,
                      color: isRoomChanged
                          ? Colors.amber.shade800
                          : theme.colorScheme.primary.withValues(alpha: 0.75),
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Text(
                        lesson.room.isNotEmpty ? lesson.room : 'Ауд. не указана',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color: isRoomChanged
                              ? Colors.amber.shade900
                              : theme.textTheme.bodySmall?.color,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showLessonDetailModal(BuildContext context, Lesson lesson, DateTime dt) {
    final theme = Theme.of(context);
    final weekdayFull = _weekdaysFullRu[dt.weekday - 1];
    final monthGen = _monthsGenitiveRu[dt.month - 1];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.only(top: 12, bottom: 24),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.dividerColor.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 14),

                // Заголовок модального окна с датой
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Icon(Icons.event_note_rounded, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        '$weekdayFull, ${dt.day} $monthGen',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 16),

                // Полноразмерная карточка пары
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: LessonCard(lesson: lesson),
                ),
                const SizedBox(height: 12),

                // Кнопка перехода к этому дню в дневном режиме
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _switchToDayFromWeek(dt);
                    },
                    icon: const Icon(Icons.calendar_today_rounded, size: 18),
                    label: const Text('Перейти к расписанию на этот день'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _getLessonTypeColor(String type) {
    switch (type) {
      case 'Лекция':
        return Colors.blue.shade600;
      case 'Практика':
        return Colors.indigo.shade600;
      case 'Лабораторная':
        return Colors.orange.shade700;
      case 'Семинар':
        return Colors.teal.shade600;
      case 'Военная подготовка':
        return Colors.green.shade700;
      case 'Защита':
        return Colors.purple.shade600;
      case 'Зачет':
      case 'Экзамен':
        return Colors.red.shade600;
      default:
        return Colors.indigo.shade600;
    }
  }
}
