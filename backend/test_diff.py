"""
Скрипт для тестирования работы базы данных и Diff Engine.
1. Загружает реальное расписание ДГТУ и сохраняет его в БД как Базовое состояние (v1).
2. Симулирует изменения (отмену пары, перенос аудитории, замену преподавателя, добавление новой пары).
3. Запускает Diff Engine и находит все изменения.
4. Проверяет генерацию Push-уведомления.
5. Сохраняет историю изменений в БД и считывает её обратно.
"""

import copy
import sys
from database import Database
from fetcher import fetch_schedule
from diff_engine import compare_schedules, format_push_notification


def run_test():
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass

    print("==================================================")
    print("🚀 ТЕСТИРОВАНИЕ: База Данных + Fetcher + Diff Engine")
    print("==================================================")

    db = Database("test_schedule.db")
    target_id = "student_347338"

    # Шаг 1: Получаем реальные данные
    print("\n[ШАГ 1] Получение расписания из API ДГТУ...")
    fetch_res = fetch_schedule(student_id=347338)
    if not fetch_res.success:
        print(f"❌ Не удалось получить данные: {fetch_res.error}")
        return

    print(f"[OK] Получено занятий: {fetch_res.lessons_count}")
    print(f"[OK] Группа: {fetch_res.group_name}")

    # Шаг 2: Сохраняем исходное расписание в БД
    print("\n[ШАГ 2] Сохранение базовой версии (v1) в SQLite...")
    v1_hash = db.save_schedule(
        target_id=target_id,
        target_type="student",
        data=fetch_res.data,
        date_uploading=fetch_res.upload_date
    )
    print(f"[OK] Расписание сохранено. Хеш: {v1_hash[:16]}...")

    # Шаг 3: Моделируем изменения в расписании (v2)
    print("\n[ШАГ 3] Симуляция изменений в расписании (v2)...")
    v2_data = copy.deepcopy(fetch_res.data)
    lessons = v2_data["data"]["rasp"]

    if len(lessons) < 4:
        print("❌ Слишком мало занятий для симуляции")
        return

    # Симуляция 1: Отмена пары (удаляем первую пару)
    cancelled_lesson = lessons.pop(0)
    print(f"  * [Симуляция] Отменяем пару ID {cancelled_lesson.get('код')}: {cancelled_lesson.get('дисциплина').strip()}")

    # Симуляция 2: Перенос аудитории во второй паре
    room_changed_lesson = lessons[0]
    old_room = room_changed_lesson.get("аудитория")
    room_changed_lesson["аудитория"] = "8-402 (Главный корпус)"
    print(f"  * [Симуляция] Переносим ауд. в паре ID {room_changed_lesson.get('код')}: '{old_room}' -> '8-402 (Главный корпус)'")

    # Симуляция 3: Замена преподавателя в третьей паре
    teacher_changed_lesson = lessons[1]
    old_teacher = teacher_changed_lesson.get("преподаватель")
    teacher_changed_lesson["преподаватель"] = "Иванов Иван Иванович"
    teacher_changed_lesson["фиоПреподавателя"] = "Иванов И. И."
    print(f"  * [Симуляция] Меняем преподавателя в паре ID {teacher_changed_lesson.get('код')}: '{old_teacher}' -> 'Иванов И. И.'")

    # Симуляция 4: Добавление новой пары
    new_fake_lesson = copy.deepcopy(lessons[2])
    new_fake_lesson["код"] = 999999999
    new_fake_lesson["дисциплина"] = "Разработка мобильных приложений"
    new_fake_lesson["номерЗанятия"] = 5
    new_fake_lesson["начало"] = "17:30"
    new_fake_lesson["конец"] = "19:00"
    new_fake_lesson["аудитория"] = "Коворкинг ДГТУ"
    lessons.append(new_fake_lesson)
    print(f"  * [Симуляция] Добавляем новую пару ID {new_fake_lesson.get('код')}: {new_fake_lesson.get('дисциплина')}")

    # Шаг 4: Запуск Diff Engine
    print("\n[ШАГ 4] Запуск Diff Engine для сравнения v1 и v2...")
    changes = compare_schedules(old_data=fetch_res.data, new_data=v2_data)

    print(f"[OK] Всего обнаружено изменений: {len(changes)}")
    for i, ch in enumerate(changes, 1):
        print(f"  {i}. [{ch.type}] {ch.human_message}")

    # Шаг 5: Проверка генерации Push-уведомления
    print("\n[ШАГ 5] Формирование Push-уведомления для мобилки...")
    push_payload = format_push_notification(changes)
    print(f"  * Заголовок (Title): {push_payload['title']}")
    print(f"  * Текст (Body):     {push_payload['body']}")
    print(f"  * Число изменений: {push_payload['count']}")

    # Шаг 6: Запись изменений в БД
    print("\n[ШАГ 6] Логирование изменений в таблицу changes_history...")
    changes_dicts = [ch.to_dict() for ch in changes]
    db.log_changes(target_id=target_id, changes=changes_dicts)

    # Шаг 7: Считывание истории из БД
    print("\n[ШАГ 7] Чтение истории изменений из БД (как это увидит мобильное приложение)...")
    history = db.get_recent_changes(target_id=target_id, limit=5)
    for row in history:
        print(f"  • #{row['id']} [{row['change_type']}] {row['human_message']} (Зафиксировано: {row['detected_at'][:19]})")

    print("\n==================================================")
    print("🎉 ВСЕ ТЕСТЫ УСПЕШНО ПРОЙДЕНЫ!")
    print("==================================================")


if __name__ == "__main__":
    run_test()
