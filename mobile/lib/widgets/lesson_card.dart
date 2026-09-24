import 'package:flutter/material.dart';
import '../models/lesson.dart';

class LessonCard extends StatelessWidget {
  final Lesson lesson;
  final bool isSplit;

  const LessonCard({
    super.key, 
    required this.lesson, 
    this.isSplit = false,
  });

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
      case 'Защита':
        return Colors.purple.shade600;
      case 'Зачет':
      case 'Экзамен':
        return Colors.red.shade600;
      default:
        return Colors.indigo.shade600;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCancelled = lesson.isCancelled;
    final isRoomChanged = lesson.isRoomChanged;
    final isTeacherChanged = lesson.isTeacherChanged;
    final isTimeChanged = lesson.isTimeChanged;
    final isNew = lesson.isNew;
    final badgeColor = _getBadgeColor(lesson.lessonType);

    // Определение цветовых акцентов карточки
    Color cardBorderColor;
    Color cardBgColor;
    double borderWidth = 1.0;

    if (isCancelled) {
      cardBorderColor = Colors.redAccent.withValues(alpha: 0.4);
      cardBgColor = theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3);
    } else if (isNew) {
      cardBorderColor = Colors.green.shade600;
      cardBgColor = Colors.green.withValues(alpha: 0.06);
      borderWidth = 1.5;
    } else if (isRoomChanged) {
      cardBorderColor = Colors.amber.shade600;
      cardBgColor = Colors.amber.withValues(alpha: 0.08);
      borderWidth = 1.5;
    } else if (isTeacherChanged) {
      cardBorderColor = Colors.purple.shade600;
      cardBgColor = Colors.purple.withValues(alpha: 0.06);
      borderWidth = 1.5;
    } else if (isTimeChanged) {
      cardBorderColor = Colors.teal.shade600;
      cardBgColor = Colors.teal.withValues(alpha: 0.06);
      borderWidth = 1.5;
    } else {
      cardBorderColor = theme.dividerColor.withValues(alpha: 0.2);
      cardBgColor = theme.colorScheme.surface;
    }

    // Бейдж статуса
    Widget? statusBadge;
    if (isCancelled) {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
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
      );
    } else if (isNew) {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.green.shade600),
        ),
        child: Text(
          '➕ ДОБАВЛЕНА',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: Colors.green.shade800,
          ),
        ),
      );
    } else if (isRoomChanged) {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.amber.shade700),
        ),
        child: Text(
          isSplit ? '⚠️ СМЕНА АУД.' : '⚠️ АУДИТОРИЯ ПЕРЕНЕСЕНА',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: Colors.amber.shade900,
          ),
        ),
      );
    } else if (isTeacherChanged) {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.purple.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.purple.shade600),
        ),
        child: Text(
          isSplit ? '👤 ЗАМЕНА ПРЕПОД.' : '👤 ПРЕПОДАВАТЕЛЬ ЗАМЕНЕН',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: Colors.purple.shade800,
          ),
        ),
      );
    } else if (isTimeChanged) {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.teal.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.teal.shade600),
        ),
        child: Text(
          isSplit ? '⏰ ВРЕМЯ' : '⏰ ВРЕМЯ ИЗМЕНЕНО',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: Colors.teal.shade800,
          ),
        ),
      );
    }

    final typeBadge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: isCancelled
            ? Colors.grey.withValues(alpha: 0.15)
            : badgeColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isCancelled
              ? Colors.grey.withValues(alpha: 0.3)
              : badgeColor.withValues(alpha: 0.25),
        ),
      ),
      child: Text(
        lesson.lessonType,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: isCancelled ? Colors.grey : badgeColor,
        ),
      ),
    );

    // --- Вариант для разделенной ячейки (половина строки) ---
    if (isSplit) {
      Widget splitCard = Container(
        decoration: BoxDecoration(
          color: cardBgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cardBorderColor,
            width: borderWidth,
          ),
          boxShadow: isCancelled ? null : [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 4,
              offset: const Offset(0, 1),
            )
          ],
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                if (statusBadge != null) statusBadge,
                typeBadge,
              ],
            ),
            const SizedBox(height: 6),
            Text(
              lesson.subject,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                decoration: isCancelled ? TextDecoration.lineThrough : null,
                decorationColor: Colors.redAccent,
                decorationThickness: 2.0,
                color: isCancelled 
                    ? theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6) 
                    : theme.textTheme.titleMedium?.color,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  Icons.place_outlined, 
                  size: 13, 
                  color: isRoomChanged ? Colors.amber.shade900 : theme.colorScheme.primary
                ),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(
                    lesson.room.isNotEmpty ? lesson.room : "Ауд. не указана",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      decoration: isCancelled ? TextDecoration.lineThrough : null,
                      color: isRoomChanged
                          ? Colors.amber.shade900
                          : theme.textTheme.bodyMedium?.color,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (lesson.teacher.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                '👤 ${lesson.teacher}',
                style: TextStyle(
                  fontSize: 10.5,
                  decoration: isCancelled ? TextDecoration.lineThrough : null,
                  color: isTeacherChanged
                      ? Colors.purple.shade800
                      : theme.textTheme.bodySmall?.color?.withValues(alpha: 0.8),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (lesson.changeNote != null && lesson.changeNote!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                lesson.changeNote!,
                style: TextStyle(
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w500,
                  color: isCancelled ? Colors.redAccent : Colors.amber.shade900,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      );

      if (isCancelled) {
        return Opacity(
          opacity: 0.6,
          child: splitCard,
        );
      }
      return splitCard;
    }

    // --- Стандартный полноразмерный вариант карточки ---
    Widget cardContent = Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: cardBgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: cardBorderColor,
          width: borderWidth,
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
                        : (isRoomChanged 
                            ? Colors.amber.shade800 
                            : (isTeacherChanged 
                                ? Colors.purple.shade800 
                                : theme.colorScheme.primary)),
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
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (statusBadge != null) statusBadge,
                        typeBadge,
                      ],
                    ),

                    // Бейдж аудитории
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: isRoomChanged
                            ? Colors.amber.withValues(alpha: 0.15)
                            : theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isRoomChanged
                              ? Colors.amber.shade700
                              : theme.dividerColor.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        '📍 ${lesson.room.isNotEmpty ? lesson.room : "Ауд. не указана"}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          decoration: isCancelled ? TextDecoration.lineThrough : null,
                          color: isRoomChanged
                              ? Colors.amber.shade900
                              : theme.textTheme.bodyMedium?.color,
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
                      color: isTeacherChanged
                          ? Colors.purple.shade800
                          : theme.textTheme.bodySmall?.color?.withValues(alpha: 0.8),
                    ),
                  ),

                // Тема занятия (если указана в расписании)
                if (lesson.theme != null && lesson.theme!.isNotEmpty && !isCancelled)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '📖 ${lesson.theme!}',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.75),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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
                        color: isCancelled 
                            ? Colors.redAccent 
                            : (isTeacherChanged 
                                ? Colors.purple.shade800 
                                : Colors.amber.shade800),
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
