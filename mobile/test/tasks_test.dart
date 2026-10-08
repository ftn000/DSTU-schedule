import 'package:flutter_test/flutter_test.dart';
import 'package:dstu_schedule/models/task_item.dart';
import 'package:dstu_schedule/models/lesson.dart';

void main() {
  group('Lesson cleanSubjectName Tests', () {
    test('removes semesters and versions according to rules', () {
      expect(
        Lesson.cleanSubjectName('Игровые стартапы (7 семестр)'),
        'Игровые стартапы',
      );
      expect(
        Lesson.cleanSubjectName('Внедрение и маркетинг игр (7 семестр)'),
        'Внедрение и маркетинг игр',
      );
      expect(
        Lesson.cleanSubjectName('Программирование мобильных игр (7 семестр, 26-27) V2'),
        'Программирование мобильных игр',
      );
      expect(
        Lesson.cleanSubjectName('Менеджмент игрового проекта (7 семестр, 26-27) (v2)'),
        'Менеджмент игрового проекта',
      );
      expect(
        Lesson.cleanSubjectName('Менеджмент игрового проекта (7 семестр)'),
        'Менеджмент игрового проекта',
      );
      expect(
        Lesson.cleanSubjectName('Левел-дизайн ( 6 семестр)'),
        'Левел-дизайн',
      );
      expect(
        Lesson.cleanSubjectName('Компьютерная графика (3D)'),
        'Компьютерная графика (3D)',
      );
      expect(
        Lesson.cleanSubjectName('пр. Игровые стартапы (7 семестр)'),
        'Игровые стартапы',
      );
    });

    test('Lesson.fromJson automatically cleans subject and parses prefix without RangeError', () {
      final json = {
        'код': 123,
        'дисциплина': 'пр. Программирование мобильных игр (7 семестр, 26-27) V2',
        'номерЗанятия': 2,
        'начало': '10:15',
        'конец': '11:50',
        'дата': '2026-10-06T00:00:00',
        'деньНедели': 2,
      };
      final lesson = Lesson.fromJson(json);
      expect(lesson.subject, 'Программирование мобильных игр');
      expect(lesson.rawSubject, 'пр. Программирование мобильных игр (7 семестр, 26-27) V2');
      expect(lesson.lessonType, 'Практика');

      final jsonLec = {
        'код': 124,
        'дисциплина': 'лек. Компьютерная графика',
        'номерЗанятия': 1,
        'начало': '08:30',
        'конец': '10:05',
        'дата': '2026-10-06T00:00:00',
        'деньНедели': 2,
      };
      final lessonLec = Lesson.fromJson(jsonLec);
      expect(lessonLec.subject, 'Компьютерная графика');
      expect(lessonLec.lessonType, 'Лекция');
    });

    test('TaskItem.fromJson automatically cleans subject', () {
      final json = {
        'id': 5,
        'group_name': 'Т.РИ42',
        'subject': 'Менеджмент игрового проекта (7 семестр, 26-27) (v2)',
        'title': 'Практика 1',
        'created_at': '2026-10-06T00:00:00',
        'updated_at': '2026-10-06T00:00:00',
      };
      final item = TaskItem.fromJson(json);
      expect(item.subject, 'Менеджмент игрового проекта');
    });
  });

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
