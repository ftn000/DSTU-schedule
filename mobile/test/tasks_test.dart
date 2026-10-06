import 'package:flutter_test/flutter_test.dart';
import 'package:dstu_schedule/models/task_item.dart';

void main() {
  group('TaskItem Semester Tests', () {
    test('formatSemesterFromDate correctly calculates autumn and spring', () {
      expect(TaskItem.formatSemesterFromDate(DateTime(2026, 9, 1)), 'Осень 2026');
      expect(TaskItem.formatSemesterFromDate(DateTime(2026, 11, 20)), 'Осень 2026');
      expect(TaskItem.formatSemesterFromDate(DateTime(2027, 1, 15)), 'Осень 2026');
      expect(TaskItem.formatSemesterFromDate(DateTime(2026, 2, 1)), 'Весна 2026');
      expect(TaskItem.formatSemesterFromDate(DateTime(2026, 5, 30)), 'Весна 2026');
      expect(TaskItem.formatSemesterFromDate(DateTime(2025, 10, 10)), 'Осень 2025');
    });

    test('compareSemesters sorts semesters chronologically descending', () {
      final list = ['Весна 2025', 'Осень 2026', 'Весна 2026', 'Осень 2025'];
      list.sort(TaskItem.compareSemesters);
      expect(list, ['Осень 2026', 'Весна 2026', 'Осень 2025', 'Весна 2025']);
    });

    test('resolvedSemester prioritizes explicit semester, then dates', () {
      final taskWithExplicit = TaskItem(
        id: 1,
        groupName: 'ВПР42',
        subject: 'Тест',
        title: 'Работа 1',
        lessonDate: '2026-10-01',
        semester: 'Весна 2026',
        createdAt: '2026-10-01T00:00:00',
        updatedAt: '2026-10-01T00:00:00',
      );
      expect(taskWithExplicit.resolvedSemester, 'Весна 2026');

      final taskFromDate = TaskItem(
        id: 2,
        groupName: 'ВПР42',
        subject: 'Тест',
        title: 'Работа 2',
        lessonDate: '2026-10-15',
        createdAt: '2026-10-01T00:00:00',
        updatedAt: '2026-10-01T00:00:00',
      );
      expect(taskFromDate.resolvedSemester, 'Осень 2026');
    });

    test('TaskItem fromJson and toJson preserves semester field', () {
      final json = {
        'id': 10,
        'group_name': 'ВПР42',
        'subject': 'Математика',
        'title': 'Практика 3',
        'lesson_type': 'Практика',
        'semester': 'Осень 2026',
        'created_at': '2026-10-01T00:00:00',
        'updated_at': '2026-10-01T00:00:00',
      };

      final item = TaskItem.fromJson(json);
      expect(item.semester, 'Осень 2026');
      expect(item.resolvedSemester, 'Осень 2026');

      final serialized = item.toJson();
      expect(serialized['semester'], 'Осень 2026');
    });
  });
}
