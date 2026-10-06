import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/task_item.dart';
import '../models/lesson.dart';
import '../services/tasks_service.dart';
import '../services/api_service.dart';

class TasksScreen extends StatefulWidget {
  final int studentId;
  final String? initialGroupName;
  final List<Lesson>? currentScheduleLessons;

  const TasksScreen({
    super.key,
    required this.studentId,
    this.initialGroupName,
    this.currentScheduleLessons,
  });

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  final TasksService _tasksService = TasksService();
  final ApiService _apiService = ApiService();

  bool _isLoading = true;
  String? _errorMessage;
  String _groupName = 'ВПР42';
  List<TaskItem> _tasks = [];

  late String _selectedSemester;
  String _selectedSubject = 'Все';
  TaskStatus? _selectedStatusFilter;

  @override
  void initState() {
    super.initState();
    _selectedSemester = TaskItem.getCurrentSemesterName();
    _initAndLoad();
  }

  Future<void> _initAndLoad() async {
    setState(() => _isLoading = true);
    if (widget.initialGroupName != null && widget.initialGroupName!.isNotEmpty) {
      _groupName = widget.initialGroupName!;
    } else {
      final savedGroup = await _apiService.getSavedGroupName();
      if (savedGroup != null && savedGroup.isNotEmpty) {
        _groupName = savedGroup;
      }
    }
    await _loadTasks();
  }

  Future<void> _loadTasks({bool forceRefresh = false}) async {
    try {
      final list = await _tasksService.getTasks(
        _groupName,
        studentId: widget.studentId.toString(),
        forceRefresh: forceRefresh,
      );
      if (mounted) {
        setState(() {
          _tasks = list;
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Не удалось загрузить задания: $e';
        });
      }
    }
  }

  Future<void> _syncSchedule() async {
    setState(() => _isLoading = true);
    try {
      List<Lesson> lessons = widget.currentScheduleLessons ?? [];
      if (lessons.isEmpty) {
        final res = await _apiService.getSchedule(widget.studentId);
        lessons = res.lessons;
      }

      final createdCount = await _tasksService.syncScheduleTasks(_groupName, lessons);
      await _loadTasks(forceRefresh: true);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              createdCount > 0
                  ? 'Синхронизировано: добавлено новых заданий — $createdCount'
                  : 'Все практики и лабораторные уже синхронизированы',
            ),
            backgroundColor: createdCount > 0 ? const Color(0xFF1E40AF) : Colors.grey[800],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка синхронизации: $e'), backgroundColor: Colors.red),
        );
        setState(() => _isLoading = false);
      }
    }
  }

  List<String> get _availableSemesters {
    final currentSem = TaskItem.getCurrentSemesterName();
    final semSet = <String>{currentSem};
    for (final t in _tasks) {
      semSet.add(t.resolvedSemester);
    }
    final sorted = semSet.toList()..sort(TaskItem.compareSemesters);
    return [...sorted, 'Все'];
  }

  int _getTaskCountForSemester(String sem) {
    if (sem == 'Все') return _tasks.length;
    return _tasks.where((t) => t.resolvedSemester == sem).length;
  }

  List<TaskItem> get _semesterTasks {
    if (_selectedSemester == 'Все') {
      return _tasks;
    }
    return _tasks.where((t) => t.resolvedSemester == _selectedSemester).toList();
  }

  List<String> get _subjects {
    final set = <String>{};
    for (final t in _semesterTasks) {
      if (t.subject.isNotEmpty) {
        set.add(t.subject);
      }
    }
    final sorted = set.toList()..sort();
    return ['Все', ...sorted];
  }

  List<TaskItem> get _filteredTasks {
    return _semesterTasks.where((t) {
      if (_selectedSubject != 'Все' && t.subject != _selectedSubject) {
        return false;
      }
      if (_selectedStatusFilter != null && t.currentStatus != _selectedStatusFilter) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Задания и практики',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            Text(
              'Группа $_groupName',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.grey[400] : Colors.grey[600],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Синхронизировать с расписанием',
            icon: const Icon(Icons.sync),
            onPressed: _syncSchedule,
          ),
          IconButton(
            tooltip: 'Обновить',
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadTasks(forceRefresh: true),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateTaskDialog,
        icon: const Icon(Icons.add),
        label: const Text('Задание'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline, size: 48, color: Colors.orange),
                        const SizedBox(height: 16),
                        Text(_errorMessage!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () => _loadTasks(forceRefresh: true),
                          child: const Text('Повторить попытку'),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    _buildSemesterTabs(isDark),
                    _buildFiltersBar(isDark),
                    Expanded(
                      child: _filteredTasks.isEmpty
                          ? _buildEmptyState(isDark)
                          : RefreshIndicator(
                              onRefresh: () => _loadTasks(forceRefresh: true),
                              child: ListView.builder(
                                padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                                itemCount: _filteredTasks.length,
                                itemBuilder: (context, index) {
                                  final task = _filteredTasks[index];
                                  return _buildTaskCard(task, isDark);
                                },
                              ),
                            ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildSemesterTabs(bool isDark) {
    final currentSem = TaskItem.getCurrentSemesterName();
    final semesters = _availableSemesters;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.06),
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: semesters.map((sem) {
            final isSelected = _selectedSemester == sem;
            final isCurrent = sem == currentSem;
            final count = _getTaskCountForSemester(sem);

            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      setState(() {
                        _selectedSemester = sem;
                        if (_selectedSubject != 'Все' && !_subjects.contains(_selectedSubject)) {
                          _selectedSubject = 'Все';
                        }
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF2563EB)
                            : (isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9)),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFF2563EB)
                              : (isCurrent
                                  ? const Color(0xFF3B82F6)
                                  : (isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.08))),
                          width: isCurrent && !isSelected ? 1.5 : 1.0,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isCurrent && !isSelected) ...[
                            Container(
                              width: 6,
                              height: 6,
                              margin: const EdgeInsets.only(right: 6),
                              decoration: const BoxDecoration(
                                color: Color(0xFF3B82F6),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                          Text(
                            sem,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                              color: isSelected
                                  ? Colors.white
                                  : (isDark ? Colors.grey[200] : Colors.grey[800]),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? Colors.white.withValues(alpha: 0.25)
                                  : (isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.07)),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$count',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isSelected
                                    ? Colors.white
                                    : (isDark ? Colors.grey[300] : Colors.grey[700]),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildFiltersBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06),
          ),
        ),
      ),
      child: Column(
        children: [
          // Фильтр по статусам
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _buildStatusChip(null, 'Все (${_semesterTasks.length})', isDark),
                const SizedBox(width: 8),
                _buildStatusChip(
                  TaskStatus.todo,
                  'Не начато (${_semesterTasks.where((t) => t.currentStatus == TaskStatus.todo).length})',
                  isDark,
                ),
                const SizedBox(width: 8),
                _buildStatusChip(
                  TaskStatus.inProgress,
                  'В процессе (${_semesterTasks.where((t) => t.currentStatus == TaskStatus.inProgress).length})',
                  isDark,
                ),
                const SizedBox(width: 8),
                _buildStatusChip(
                  TaskStatus.submitted,
                  'Сдано (${_semesterTasks.where((t) => t.currentStatus == TaskStatus.submitted).length})',
                  isDark,
                ),
                const SizedBox(width: 8),
                _buildStatusChip(
                  TaskStatus.accepted,
                  'Зачтено (${_semesterTasks.where((t) => t.currentStatus == TaskStatus.accepted).length})',
                  isDark,
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // Фильтр по предметам
          if (_subjects.length > 2)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: _subjects.map((subj) {
                  final isSelected = _selectedSubject == subj;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(subj, style: const TextStyle(fontSize: 12)),
                      selected: isSelected,
                      onSelected: (val) {
                        setState(() => _selectedSubject = subj);
                      },
                      visualDensity: VisualDensity.compact,
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(TaskStatus? status, String label, bool isDark) {
    final isSelected = _selectedStatusFilter == status;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? Colors.white : (isDark ? Colors.grey[300] : Colors.grey[800]),
        ),
      ),
      selected: isSelected,
      selectedColor: status?.color ?? const Color(0xFF2563EB),
      onSelected: (val) {
        setState(() => _selectedStatusFilter = val ? status : null);
      },
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.assignment_outlined,
              size: 64,
              color: isDark ? Colors.white24 : Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              _tasks.isEmpty ? 'Заданий пока нет' : 'Нет заданий по выбранному фильтру',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _tasks.isEmpty
                  ? 'Вы можете синхронизировать практики из расписания или добавить задание вручную.'
                  : 'Попробуйте сбросить фильтры поиска.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: isDark ? Colors.grey[400] : Colors.grey[600]),
            ),
            if (_tasks.isEmpty) ...[
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _syncSchedule,
                icon: const Icon(Icons.sync),
                label: const Text('Синхронизировать из расписания'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTaskCard(TaskItem task, bool isDark) {
    final status = task.currentStatus;
    final taskFilesCount = task.taskFiles.length;
    final solFilesCount = task.submission?.files.length ?? 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openTaskDetail(task),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Верхняя строка: Предмет + Бейдж статуса
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        Text(
                          task.subject,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isDark ? const Color(0xFF93C5FD) : const Color(0xFF1E40AF),
                          ),
                        ),
                        if (_selectedSemester == 'Все')
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              task.resolvedSemester,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: status.color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: status.color.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: status.color,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          status.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: status.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Название задания
              Text(
                task.title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.2,
                ),
              ),
              if (task.description != null && task.description!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  task.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.grey[400] : Colors.grey[600],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              // Нижняя панель: дата/дедлайн и индикаторы файлов
              Row(
                children: [
                  if (task.lessonDate != null && task.lessonDate!.isNotEmpty) ...[
                    Icon(Icons.calendar_today_outlined, size: 14, color: isDark ? Colors.grey[400] : Colors.grey[600]),
                    const SizedBox(width: 4),
                    Text(
                      task.lessonDate!,
                      style: TextStyle(fontSize: 12, color: isDark ? Colors.grey[400] : Colors.grey[600]),
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (task.deadline != null && task.deadline!.isNotEmpty) ...[
                    const Icon(Icons.timer_outlined, size: 14, color: Colors.amber),
                    const SizedBox(width: 4),
                    Text(
                      'до ${task.deadline}',
                      style: const TextStyle(fontSize: 12, color: Colors.amber, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 12),
                  ],
                  const Spacer(),
                  if (taskFilesCount > 0) ...[
                    Icon(Icons.attach_file, size: 16, color: isDark ? Colors.grey[400] : Colors.grey[600]),
                    const SizedBox(width: 2),
                    Text(
                      '$taskFilesCount',
                      style: TextStyle(fontSize: 12, color: isDark ? Colors.grey[400] : Colors.grey[600]),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (solFilesCount > 0) ...[
                    const Icon(Icons.upload_file, size: 16, color: Color(0xFF60A5FA)),
                    const SizedBox(width: 2),
                    Text(
                      '$solFilesCount',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF60A5FA), fontWeight: FontWeight.bold),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openTaskDetail(TaskItem task) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _TaskDetailSheet(
        task: task,
        studentId: widget.studentId.toString(),
        onUpdated: () => _loadTasks(forceRefresh: true),
      ),
    );
  }

  void _openCreateTaskDialog() {
    final titleCtrl = TextEditingController();
    final subjectCtrl = TextEditingController(text: _selectedSubject != 'Все' ? _selectedSubject : '');
    final descCtrl = TextEditingController();
    final deadlineCtrl = TextEditingController();
    String lessonType = 'Практика';
    String selectedSemesterInDialog = _selectedSemester != 'Все'
        ? _selectedSemester
        : TaskItem.getCurrentSemesterName();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Добавить занятие / практику'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: subjectCtrl,
                  decoration: const InputDecoration(labelText: 'Дисциплина / Предмет *'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(labelText: 'Название / Тема *'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedSemesterInDialog,
                  decoration: const InputDecoration(labelText: 'Семестр'),
                  items: _availableSemesters
                      .where((s) => s != 'Все')
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) setDialogState(() => selectedSemesterInDialog = val);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: lessonType,
                  decoration: const InputDecoration(labelText: 'Тип занятия'),
                  items: const [
                    DropdownMenuItem(value: 'Практика', child: Text('Практика')),
                    DropdownMenuItem(value: 'Лабораторная', child: Text('Лабораторная работа')),
                    DropdownMenuItem(value: 'Семинар', child: Text('Семинар')),
                    DropdownMenuItem(value: 'Проект', child: Text('Проект')),
                  ],
                  onChanged: (val) {
                    if (val != null) setDialogState(() => lessonType = val);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: deadlineCtrl,
                  decoration: const InputDecoration(labelText: 'Дедлайн (например: 2026-10-15)'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Описание / задание методички'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (subjectCtrl.text.trim().isEmpty || titleCtrl.text.trim().isEmpty) return;

                final newTask = TaskItem(
                  id: 0,
                  groupName: _groupName,
                  subject: Lesson.cleanSubjectName(subjectCtrl.text.trim()),
                  title: titleCtrl.text.trim(),
                  lessonType: lessonType,
                  semester: selectedSemesterInDialog,
                  deadline: deadlineCtrl.text.trim().isNotEmpty ? deadlineCtrl.text.trim() : null,
                  description: descCtrl.text.trim().isNotEmpty ? descCtrl.text.trim() : null,
                  createdBy: widget.studentId.toString(),
                  createdAt: DateTime.now().toIso8601String(),
                  updatedAt: DateTime.now().toIso8601String(),
                );

                Navigator.pop(ctx);
                await _tasksService.createOrUpdateTask(newTask);
                await _loadTasks(forceRefresh: true);
              },
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Модальный экран подробностей задания: методичка, решение и загрузка файлов
class _TaskDetailSheet extends StatefulWidget {
  final TaskItem task;
  final String studentId;
  final VoidCallback onUpdated;

  const _TaskDetailSheet({
    required this.task,
    required this.studentId,
    required this.onUpdated,
  });

  @override
  State<_TaskDetailSheet> createState() => _TaskDetailSheetState();
}

class _TaskDetailSheetState extends State<_TaskDetailSheet> {
  final TasksService _tasksService = TasksService();
  late TaskStatus _currentStatus;
  late TextEditingController _solutionController;
  bool _isSavingSolution = false;
  bool _isUploadingFile = false;

  @override
  void initState() {
    super.initState();
    _currentStatus = widget.task.currentStatus;
    _solutionController = TextEditingController(
      text: widget.task.submission?.textSolution ?? '',
    );
  }

  @override
  void dispose() {
    _solutionController.dispose();
    super.dispose();
  }

  Future<void> _updateStatus(TaskStatus status) async {
    setState(() => _currentStatus = status);
    await _tasksService.saveSubmission(
      widget.task.id,
      widget.studentId,
      status,
      textSolution: _solutionController.text,
    );
    widget.onUpdated();
  }

  Future<void> _saveSolutionText() async {
    setState(() => _isSavingSolution = true);
    await _tasksService.saveSubmission(
      widget.task.id,
      widget.studentId,
      _currentStatus,
      textSolution: _solutionController.text,
    );
    setState(() => _isSavingSolution = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Текст решения сохранен')),
      );
    }
    widget.onUpdated();
  }

  Future<void> _pickAndUploadFile(String fileType) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'pdf', 'doc', 'docx', 'txt', 'zip', 'rar', '7z',
        'dart', 'py', 'cpp', 'c', 'cs', 'java', 'js', 'ts', 'html', 'css', 'sql', 'png', 'jpg'
      ],
    );

    if (result != null && result.files.single.path != null) {
      final file = result.files.single;
      // Проверка размера <= 50 МБ
      if (file.size > 50 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Файл превышает лимит 50 МБ'), backgroundColor: Colors.red),
          );
        }
        return;
      }

      setState(() => _isUploadingFile = true);
      final uploaded = await _tasksService.uploadFile(
        taskId: widget.task.id,
        filePath: file.path!,
        fileName: file.name,
        fileType: fileType,
        studentId: widget.studentId,
      );
      setState(() => _isUploadingFile = false);

      if (uploaded != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Файл "${file.name}" успешно загружен!')),
          );
        }
        widget.onUpdated();
        if (mounted) Navigator.pop(context);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Ошибка загрузки файла на сервер'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _deleteFile(int fileId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удаление файла'),
        content: const Text('Удалить этот файл с сервера?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _tasksService.deleteFile(fileId);
      widget.onUpdated();
      if (mounted) Navigator.pop(context);
    }
  }

  void _downloadOrOpenFile(int fileId) async {
    final url = _tasksService.getFileDownloadUrl(fileId);
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF0F172A) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Хэндл для перетаскивания
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                children: [
                  // Заголовок
                  Text(
                    widget.task.subject,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? const Color(0xFF93C5FD) : const Color(0xFF1E40AF),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.task.title,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2563EB).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          widget.task.resolvedSemester,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF3B82F6),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        widget.task.lessonType,
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.grey[400] : Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                  if (widget.task.lessonDate != null && widget.task.lessonDate!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.calendar_today_outlined, size: 14, color: isDark ? Colors.grey[400] : Colors.grey[600]),
                        const SizedBox(width: 6),
                        Text(
                          'Дата занятия: ${widget.task.lessonDate}',
                          style: TextStyle(fontSize: 13, color: isDark ? Colors.grey[400] : Colors.grey[600]),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),

                  // Статус задания (переключатель)
                  const Text('Статус выполнения:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: TaskStatus.values.map((st) {
                        final isSel = _currentStatus == st;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(st.label),
                            selected: isSel,
                            selectedColor: st.color,
                            labelStyle: TextStyle(
                              color: isSel ? Colors.white : (isDark ? Colors.grey[300] : Colors.black87),
                              fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                            ),
                            onSelected: (val) {
                              if (val) _updateStatus(st);
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const Divider(height: 32),

                  // Блок 1: Задание (Методичка)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '📚 Задание и методичка',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      TextButton.icon(
                        onPressed: _isUploadingFile ? null : () => _pickAndUploadFile('task_attachment'),
                        icon: const Icon(Icons.attach_file, size: 18),
                        label: const Text('Прикрепить'),
                      ),
                    ],
                  ),
                  if (widget.task.description != null && widget.task.description!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        widget.task.description!,
                        style: const TextStyle(fontSize: 14, height: 1.4),
                      ),
                    ),
                  ],
                  if (widget.task.taskFiles.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    ...widget.task.taskFiles.map((f) => _buildFileTile(f, isDark, canDelete: false)),
                  ],
                  const Divider(height: 36),

                  // Блок 2: Моя реализация
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '✍️ Моя реализация (Решение)',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      TextButton.icon(
                        onPressed: _isUploadingFile ? null : () => _pickAndUploadFile('submission_attachment'),
                        icon: const Icon(Icons.upload_file, size: 18),
                        label: const Text('Файл (до 50МБ)'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _solutionController,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: 'Заметки, ссылка на репозиторий GitHub или описание решения...',
                      filled: true,
                      fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton.icon(
                      onPressed: _isSavingSolution ? null : _saveSolutionText,
                      icon: _isSavingSolution
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.save, size: 18),
                      label: const Text('Сохранить заметку'),
                    ),
                  ),
                  if (widget.task.submission?.files.isNotEmpty ?? false) ...[
                    const SizedBox(height: 12),
                    const Text('Прикрепленные файлы решения:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    ...widget.task.submission!.files.map((f) => _buildFileTile(f, isDark, canDelete: true)),
                  ],
                  if (_isUploadingFile) ...[
                    const SizedBox(height: 16),
                    const Center(
                      child: Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 8),
                          Text('Загрузка файла на сервер...'),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileTile(TaskFile file, bool isDark, {required bool canDelete}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.grey[100],
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          Icon(file.icon, color: const Color(0xFF3B82F6), size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                ),
                Text(
                  file.formattedSize,
                  style: TextStyle(fontSize: 11, color: isDark ? Colors.grey[400] : Colors.grey[600]),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Скачать/Открыть',
            icon: const Icon(Icons.download, size: 20),
            onPressed: () => _downloadOrOpenFile(file.id),
          ),
          if (canDelete)
            IconButton(
              tooltip: 'Удалить файл',
              icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
              onPressed: () => _deleteFile(file.id),
            ),
        ],
      ),
    );
  }
}
