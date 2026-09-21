"""
Движок выявления изменений в расписании (Diff Engine).
Сравнивает два снимка расписания (старое и новое) и классифицирует изменения:
- CANCELLED (отменена)
- ADDED (добавлена)
- ROOM_CHANGED (перенос аудитории)
- TEACHER_CHANGED (замена преподавателя)
- TIME_CHANGED (изменение времени / номера пары)
"""

from typing import List, Dict, Any, Optional
from dataclasses import dataclass, asdict
from datetime import datetime


MONTHS_RU = {
    1: "янв", 2: "фев", 3: "мар", 4: "апр", 5: "май", 6: "июн",
    7: "июл", 8: "авг", 9: "сен", 10: "окт", 11: "ноя", 12: "дек"
}

DAYS_RU = {
    0: "Пн", 1: "Вт", 2: "Ср", 3: "Чт", 4: "Пт", 5: "Сб", 6: "Вс"
}


@dataclass
class ChangeItem:
    type: str  # CANCELLED, ADDED, ROOM_CHANGED, TEACHER_CHANGED, TIME_CHANGED, MODIFIED
    lesson_id: Optional[int]
    date: str  # YYYY-MM-DD
    lesson_num: int
    subject: str
    details: str
    human_message: str
    old_lesson: Optional[Dict[str, Any]] = None
    new_lesson: Optional[Dict[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def _format_date(date_str: str) -> str:
    """Преобразует '2026-09-24T00:00:00' в '24 сен (Чт)'."""
    try:
        clean_date = date_str.split("T")[0]
        dt = datetime.strptime(clean_date, "%Y-%m-%d")
        month = MONTHS_RU.get(dt.month, str(dt.month))
        weekday = DAYS_RU.get(dt.weekday(), "")
        return f"{dt.day} {month} ({weekday})"
    except Exception:
        return date_str[:10]


def _clean_str(val: Any) -> str:
    if val is None:
        return ""
    return str(val).strip()


def extract_lessons(data: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Извлекает массив занятий из объекта ответа API, отфильтровывая фантомные пары военной кафедры."""
    if not isinstance(data, dict):
        return []
    data_block = data.get("data", data)
    lessons = []
    if isinstance(data_block, dict):
        lessons = data_block.get("rasp", [])
    elif isinstance(data_block, list):
        lessons = data_block

    # Фильтруем фиктивные занятия военной кафедры (КДВ, Полковник)
    return [
        l for l in lessons
        if "военная кафедра" not in str(l.get("дисциплина", "")).lower()
        and "полковник" not in str(l.get("преподаватель", "")).lower()
    ]


def compare_schedules(
    old_data: Dict[str, Any], 
    new_data: Dict[str, Any],
    only_upcoming: bool = False
) -> List[ChangeItem]:
    """
    Сравнивает старое и новое расписание.
    
    :param old_data: предыдущий JSON расписания
    :param new_data: свежий JSON расписания
    :param only_upcoming: если True, учитывать изменения только на сегодня и будущее
    :return: список зафиксированных изменений ChangeItem
    """
    old_lessons = extract_lessons(old_data)
    new_lessons = extract_lessons(new_data)

    today_str = datetime.now().strftime("%Y-%m-%d")

    # Индексируем занятия по их уникальному коду из ДГТУ
    old_map: Dict[int, Dict[str, Any]] = {}
    for item in old_lessons:
        code = item.get("код")
        if code:
            old_map[code] = item

    new_map: Dict[int, Dict[str, Any]] = {}
    for item in new_lessons:
        code = item.get("код")
        if code:
            new_map[code] = item

    changes: List[ChangeItem] = []

    # 1. Проверяем пропавшие (отмененные) пары
    for code, old_item in old_map.items():
        raw_date = old_item.get("дата", "")[:10]
        if only_upcoming and raw_date < today_str:
            continue

        if code not in new_map:
            date_fmt = _format_date(old_item.get("дата", ""))
            num = old_item.get("номерЗанятия", 0)
            subj = _clean_str(old_item.get("дисциплина"))
            aud = _clean_str(old_item.get("аудитория"))
            msg = f"{date_fmt}, {num}-я пара ({subj}): пара отменена (была в ауд. {aud})"

            changes.append(ChangeItem(
                type="CANCELLED",
                lesson_id=code,
                date=raw_date,
                lesson_num=num,
                subject=subj,
                details=f"Пара отменена (исчезла из расписания). Ауд: {aud}",
                human_message=msg,
                old_lesson=old_item,
                new_lesson=None
            ))

    # 2. Проверяем новые пары и изменения в существующих
    for code, new_item in new_map.items():
        raw_date = new_item.get("дата", "")[:10]
        if only_upcoming and raw_date < today_str:
            continue

        date_fmt = _format_date(new_item.get("дата", ""))
        num = new_item.get("номерЗанятия", 0)
        subj = _clean_str(new_item.get("дисциплина"))
        new_aud = _clean_str(new_item.get("аудитория"))
        new_teacher = _clean_str(new_item.get("преподаватель") or new_item.get("фиоПреподавателя"))

        # Новая пара
        if code not in old_map:
            msg = f"{date_fmt}, {num}-я пара ({subj}): добавлена новая пара в ауд. {new_aud}"
            changes.append(ChangeItem(
                type="ADDED",
                lesson_id=code,
                date=raw_date,
                lesson_num=num,
                subject=subj,
                details=f"Добавлена новая пара. Ауд: {new_aud}, Препод: {new_teacher}",
                human_message=msg,
                old_lesson=None,
                new_lesson=new_item
            ))
            continue

        # Существующая пара — сверяем реквизиты
        old_item = old_map[code]
        old_aud = _clean_str(old_item.get("аудитория"))
        old_teacher = _clean_str(old_item.get("преподаватель") or old_item.get("фиоПреподавателя"))
        old_time = f"{old_item.get('начало')}-{old_item.get('конец')}"
        new_time = f"{new_item.get('начало')}-{new_item.get('конец')}"

        # Проверка смены аудитории
        if old_aud != new_aud:
            msg = f"{date_fmt}, {num}-я пара ({subj}): смена аудитории: {old_aud} -> {new_aud}"
            changes.append(ChangeItem(
                type="ROOM_CHANGED",
                lesson_id=code,
                date=raw_date,
                lesson_num=num,
                subject=subj,
                details=f"Аудитория изменена с '{old_aud}' на '{new_aud}'",
                human_message=msg,
                old_lesson=old_item,
                new_lesson=new_item
            ))

        # Проверка замены преподавателя
        if old_teacher != new_teacher and new_teacher:
            msg = f"{date_fmt}, {num}-я пара ({subj}): замена преподавателя: {old_teacher} -> {new_teacher}"
            changes.append(ChangeItem(
                type="TEACHER_CHANGED",
                lesson_id=code,
                date=raw_date,
                lesson_num=num,
                subject=subj,
                details=f"Преподаватель изменен с '{old_teacher}' на '{new_teacher}'",
                human_message=msg,
                old_lesson=old_item,
                new_lesson=new_item
            ))

        # Проверка изменения времени
        if old_time != new_time:
            msg = f"{date_fmt}, пара '{subj}': время изменено: {old_time} -> {new_time}"
            changes.append(ChangeItem(
                type="TIME_CHANGED",
                lesson_id=code,
                date=raw_date,
                lesson_num=num,
                subject=subj,
                details=f"Время изменено с {old_time} на {new_time}",
                human_message=msg,
                old_lesson=old_item,
                new_lesson=new_item
            ))

    # Сортируем изменения по дате и номеру пары
    changes.sort(key=lambda x: (x.date, x.lesson_num))
    return changes


def format_push_notification(changes: List[ChangeItem]) -> Optional[Dict[str, str]]:
    """
    Формирует заголовок и компактный текст для Push-уведомления.
    Объединяет изменения, чтобы не спамить пользователю.
    """
    if not changes:
        return None

    dates = sorted(list(set(ch.date for ch in changes)))
    total_count = len(changes)

    if len(dates) == 1:
        date_title = _format_date(dates[0])
        title = f"Изменение в расписании на {date_title}"
        if total_count == 1:
            body = changes[0].human_message.split("): ", 1)[-1]
            body = f"{changes[0].subject} ({changes[0].lesson_num} пара): {body}"
        else:
            # Несколько изменений в один день
            types = [ch.type for ch in changes]
            summary_parts = []
            if "CANCELLED" in types:
                summary_parts.append(f"отмен: {types.count('CANCELLED')}")
            if "ROOM_CHANGED" in types:
                summary_parts.append(f"смен ауд: {types.count('ROOM_CHANGED')}")
            if "ADDED" in types:
                summary_parts.append(f"новых пар: {types.count('ADDED')}")
            body = f"Затронуто {total_count} пар: " + ", ".join(summary_parts)
    else:
        title = "Обновление расписания!"
        body = f"Зафиксированы изменения в {total_count} парах на даты: " + ", ".join(_format_date(d) for d in dates[:3])
        if len(dates) > 3:
            body += " и др."

    return {
        "title": title,
        "body": body,
        "count": str(total_count)
    }
