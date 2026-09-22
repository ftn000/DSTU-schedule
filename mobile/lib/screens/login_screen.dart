import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import 'schedule_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _idController = TextEditingController();
  final ApiService _apiService = ApiService();

  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }

  Future<void> _submitStudentId() async {
    final text = _idController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _errorMessage = 'Пожалуйста, введите ваш ID студента';
      });
      return;
    }

    final id = int.tryParse(text);
    if (id == null || id <= 0) {
      setState(() {
        _errorMessage = 'ID должен состоять только из цифр';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Проверяем наличие расписания в ДГТУ
      final groupName = await _apiService.verifyStudentId(id);
      
      // Сохраняем ID в постоянную память устройства
      await _apiService.saveStudentId(id);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Успешно подключено! Группа: $groupName'),
          backgroundColor: Colors.green.shade700,
        ),
      );

      // Переходим к экрану расписания
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => ScheduleScreen(studentId: id),
        ),
      );
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Иконка и заголовок
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.school_rounded,
                      size: 38,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 20),

                  Text(
                    'ДГТУ Расписание',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),

                  Text(
                    'Введите персональный код студента для загрузки и отслеживания расписания',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Поле ввода ID
                  TextField(
                    controller: _idController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submitStudentId(),
                    decoration: InputDecoration(
                      labelText: 'ID студента (код)',
                      hintText: 'Например: 347338',
                      prefixIcon: const Icon(Icons.badge_outlined),
                      suffixIcon: _idController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _idController.clear();
                                setState(() => _errorMessage = null);
                              },
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      errorText: _errorMessage,
                    ),
                    onChanged: (_) {
                      if (_errorMessage != null) {
                        setState(() => _errorMessage = null);
                      }
                    },
                  ),
                  const SizedBox(height: 18),

                  // Кнопка входа
                  SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _submitStudentId,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 2,
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.5,
                              ),
                            )
                          : const Text(
                              'Подключить расписание',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Быстрая кнопка для теста
                  TextButton.icon(
                    onPressed: _isLoading
                        ? null
                        : () {
                            _idController.text = '347338';
                            _submitStudentId();
                          },
                    icon: const Icon(Icons.play_circle_outline, size: 18),
                    label: const Text('Попробовать с демо-кодом (347338)'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Карточка с подсказкой "Где найти свой ID"
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: theme.dividerColor.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.help_outline_rounded,
                              size: 18,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Где найти свой ID студента?',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: theme.textTheme.bodyMedium?.color,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '1. Перейдите на сайт edu.donstu.ru\n'
                          '2. Откройте раздел «Расписание» своей группы\n'
                          '3. На странице расписания кнопка экспорт -> ссылка: параметр idStudent=XXXXXX (это и есть ваш 6-значный код).',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.45,
                            color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
