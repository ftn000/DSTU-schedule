import 'package:flutter/material.dart';
import '../models/lesson.dart';

class LessonCard extends StatelessWidget {
  final Lesson lesson;

  const LessonCard({super.key, required this.lesson});

  Color _getBadgeColor(String type) {
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
      case 'Проект':
        return Colors.purple.shade600;
      case 'Зачет':
      case 'Экзамен':
        return Colors.red.shade600;
      default:
        return Colors.blueGrey.shade600;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCancelled = lesson.isCancelled;
    final isRoomChanged = lesson.isRoomChanged;
    final badgeColor = _getBadgeColor(lesson.lessonType);

    // Карточка с полупрозрачностью для отмененных пар
    Widget cardContent = Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: isCancelled 
            ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3)
            : (isRoomChanged 
                ? Colors.amber.withValues(alpha: 0.08) 
                : theme.colorScheme.surface),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isCancelled 
              ? Colors.redAccent.withValues(alpha: 0.4) 
              : (isRoomChanged 
                  ? Colors.amber.shade600 
                  : theme.dividerColor.withValues(alpha: 0.2)),
          width: isRoomChanged ? 1.5 : 1.0,
        ),
        boxShadow: isCancelled ? null : [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          )
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Левая колонка: Номер пары и Время
          SizedBox(
            width: 54,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  '${lesson.lessonNum} ПАРА',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isCancelled 
                        ? Colors.redAccent 
                        : (isRoomChanged ? Colors.amber.shade800 : theme.colorScheme.primary),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  lesson.startTime,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: isCancelled 
                        ? theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6) 
                        : theme.textTheme.bodyLarge?.color,
                  ),
                ),
                Text(
                  lesson.endTime,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 12),
          Container(
            width: 1,
            height: 60,
            color: theme.dividerColor.withValues(alpha: 0.2),
          ),
          const SizedBox(width: 12),

          // Правая колонка: Предмет, Аудитория, Преподаватель
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Верхние бейджи
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (isCancelled)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
                        ),
                        child: const Text(
                          '🚫 ОТМЕНЕНА',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.redAccent,
                          ),
                        ),
                      )
                    else if (isRoomChanged)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.amber.shade700),
                        ),
                        child: const Text(
                          '⚠️ АУДИТОРИЯ ПЕРЕНЕСЕНА',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.amber,
                          ),
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: badgeColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: badgeColor.withValues(alpha: 0.25)),
                        ),
                        child: Text(
                          lesson.lessonType,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: badgeColor,
                          ),
                        ),
                      ),

                    // Бейдж аудитории
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        '📍 ${lesson.room.isNotEmpty ? lesson.room : "Ауд. не указана"}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          decoration: isCancelled ? TextDecoration.lineThrough : null,
                          color: theme.textTheme.bodyMedium?.color,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 6),

                // Название предмета (зачеркнуто, если пара отменена)
                Text(
                  lesson.subject,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    decoration: isCancelled ? TextDecoration.lineThrough : null,
                    decorationColor: Colors.redAccent,
                    decorationThickness: 2.0,
                    color: isCancelled 
                        ? theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6) 
                        : theme.textTheme.titleMedium?.color,
                  ),
                ),

                const SizedBox(height: 4),

                // Преподаватель
                if (lesson.teacher.isNotEmpty)
                  Text(
                    '👤 ${lesson.teacher}',
                    style: TextStyle(
                      fontSize: 12,
                      decoration: isCancelled ? TextDecoration.lineThrough : null,
                      color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.8),
                    ),
                  ),

                // Подсказка об изменении (если есть)
                if (lesson.changeNote != null && lesson.changeNote!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      lesson.changeNote!,
                      style: TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w500,
                        color: isCancelled ? Colors.redAccent : Colors.amber.shade800,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    // Применяем полупрозрачность для отмененных пар
    if (isCancelled) {
      return Opacity(
        opacity: 0.55,
        child: cardContent,
      );
    }

    return cardContent;
  }
}
