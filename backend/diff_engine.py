"""
Движок выявления изменений в расписании (Diff Engine).
Сравнивает два снимка расписания (старое и новое) и классифицирует изменения:
- CANCELLED (отменена)
- ADDED (добавлена)
- ROOM_CHANGED (перенос аудитории)
- TEACHER_CHANGED (замена преподавателя)
- TIME_CHANGED (изменение времени / номера пары)
"""

import re
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
    old_lesson_id: Optional[int] = None

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


def _normalize_subject(s: Any) -> str:
    """Очищает название дисциплины от префиксов (лек, пр, лаб) для надёжного сравнения."""
    if not s:
        return ""
    val = str(s).strip()
    val = re.sub(r'^(?:лек|пр|лаб|сем|зач|экз|конс|кп|кр)[\.\s]+', '', val, flags=re.IGNORECASE)
    return val.strip().lower()


def _norm_room(val: Any) -> str:
    """Нормализует номер аудитории для сравнения (регистронезависимо, без лишних пробелов и дефисов)."""
    s = _clean_str(val).lower()
    return re.sub(r'[\s\-]+', '', s)


def _norm_teacher(val: Any) -> str:
    """Нормализует фамилию преподавателя для сравнения (сверяет фамилию как главное слово)."""
    s = _clean_str(val).strip()
    if not s:
        return ""
    parts = s.split()
    return parts[0].lower() if parts else ""


def _norm_time(item: Dict[str, Any]) -> str:
    """Нормализует временной слот занятия."""
    num = item.get("номерЗанятия", 0)
    start = _clean_str(item.get("начало"))
    end = _clean_str(item.get("конец"))
    return f"{num}_{start}_{end}"


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
    Сравнивает старое и новое расписание по четырем ключевым параметрам:
    1. Название предмета (subject)
    2. Аудитория (room)
    3. Преподаватель (teacher)
    4. Время / номер пары (time)

    Если совпадают 4 параметра -> пара без изменений (независимо от генерации нового 'код' сайтом ДГТУ).
    Если совпадают 3 параметра:
      - сменилась аудитория -> ROOM_CHANGED (замена аудитории)
      - сменился преподаватель -> TEACHER_CHANGED (замена преподавателя)
      - сменилось время -> TIME_CHANGED (замена времени)
    Если отменилась одна пара и появилась другая (не совпадают) -> CANCELLED + ADDED.
    """
    old_lessons = extract_lessons(old_data)
    new_lessons = extract_lessons(new_data)

    today_str = datetime.now().strftime("%Y-%m-%d")

    unmatched_old = []
    for item in old_lessons:
        raw_date = item.get("дата", "")[:10]
        if only_upcoming and raw_date < today_str:
            continue
        unmatched_old.append(item)

    unmatched_new = []
    for item in new_lessons:
        raw_date = item.get("дата", "")[:10]
        if only_upcoming and raw_date < today_str:
            continue
        unmatched_new.append(item)

    changes: List[ChangeItem] = []

    # Шаг 1: Точное совпадение всех 4 параметров на одну дату (предмет, ауд, препод, время)
    # Эти пары полностью идентичны, исключаем их из дальнейшего сопоставления
    matched_old_indices = set()
    matched_new_indices = set()

    for o_idx, o in enumerate(unmatched_old):
        o_date = o.get("дата", "")[:10]
        o_subj = _normalize_subject(o.get("дисциплина"))
        o_room = _norm_room(o.get("аудитория"))
        o_teach = _norm_teacher(o.get("преподаватель") or o.get("фиоПреподавателя"))
        o_time = _norm_time(o)

        for n_idx, n in enumerate(unmatched_new):
            if n_idx in matched_new_indices:
                continue
            n_date = n.get("дата", "")[:10]
            if o_date != n_date:
                continue

            n_subj = _normalize_subject(n.get("дисциплина"))
            n_room = _norm_room(n.get("аудитория"))
            n_teach = _norm_teacher(n.get("преподаватель") or n.get("фиоПреподавателя"))
            n_time = _norm_time(n)

            if o_subj == n_subj and o_room == n_room and o_teach == n_teach and o_time == n_time:
                matched_old_indices.add(o_idx)
                matched_new_indices.add(n_idx)
                break

    # Шаг 2: Сопоставление при совпадении 3 из 4 параметров на одну дату

    # 2.1: Смена аудитории (совпадают: название, препод, время; отличается: аудитория)
    for o_idx, o in enumerate(unmatched_old):
        if o_idx in matched_old_indices:
            continue
        o_date = o.get("дата", "")[:10]
        o_subj = _normalize_subject(o.get("дисциплина"))
        o_room = _norm_room(o.get("аудитория"))
        o_teach = _norm_teacher(o.get("преподаватель") or o.get("фиоПреподавателя"))
        o_time = _norm_time(o)

        for n_idx, n in enumerate(unmatched_new):
            if n_idx in matched_new_indices:
                continue
            n_date = n.get("дата", "")[:10]
            if o_date != n_date:
                continue

            n_subj = _normalize_subject(n.get("дисциплина"))
            n_room = _norm_room(n.get("аудитория"))
            n_teach = _norm_teacher(n.get("преподаватель") or n.get("фиоПреподавателя"))
            n_time = _norm_time(n)

            if o_subj == n_subj and o_teach == n_teach and o_time == n_time and o_room != n_room:
                matched_old_indices.add(o_idx)
                matched_new_indices.add(n_idx)

                old_aud = _clean_str(o.get("аудитория"))
                new_aud = _clean_str(n.get("аудитория"))
                date_fmt = _format_date(n.get("дата", ""))
                num = n.get("номерЗанятия", 0)
                subj = _clean_str(n.get("дисциплина"))
                msg = f"{date_fmt}, {num}-я пара ({subj}): смена аудитории: {old_aud} -> {new_aud}"

                changes.append(ChangeItem(
                    type="ROOM_CHANGED",
                    lesson_id=n.get("код") or o.get("код"),
                    old_lesson_id=o.get("код"),
                    date=o_date,
                    lesson_num=num,
                    subject=subj,
                    details=f"Аудитория изменена с '{old_aud}' на '{new_aud}'",
                    human_message=msg,
                    old_lesson=o,
                    new_lesson=n
                ))
                break

    # 2.2: Замена преподавателя (совпадают: название, аудитория, время; отличается: препод)
    for o_idx, o in enumerate(unmatched_old):
        if o_idx in matched_old_indices:
            continue
        o_date = o.get("дата", "")[:10]
        o_subj = _normalize_subject(o.get("дисциплина"))
        o_room = _norm_room(o.get("аудитория"))
        o_teach = _norm_teacher(o.get("преподаватель") or o.get("фиоПреподавателя"))
        o_time = _norm_time(o)

        for n_idx, n in enumerate(unmatched_new):
            if n_idx in matched_new_indices:
                continue
            n_date = n.get("дата", "")[:10]
            if o_date != n_date:
                continue

            n_subj = _normalize_subject(n.get("дисциплина"))
            n_room = _norm_room(n.get("аудитория"))
            n_teach = _norm_teacher(n.get("преподаватель") or n.get("фиоПреподавателя"))
            n_time = _norm_time(n)

            if o_subj == n_subj and o_room == n_room and o_time == n_time and o_teach != n_teach:
                matched_old_indices.add(o_idx)
                matched_new_indices.add(n_idx)

                old_teach_name = _clean_str(o.get("преподаватель") or o.get("фиоПреподавателя"))
                new_teach_name = _clean_str(n.get("преподаватель") or n.get("фиоПреподавателя"))
                date_fmt = _format_date(n.get("дата", ""))
                num = n.get("номерЗанятия", 0)
                subj = _clean_str(n.get("дисциплина"))
                msg = f"{date_fmt}, {num}-я пара ({subj}): замена преподавателя: {old_teach_name} -> {new_teach_name}"

                changes.append(ChangeItem(
                    type="TEACHER_CHANGED",
                    lesson_id=n.get("код") or o.get("код"),
                    old_lesson_id=o.get("код"),
                    date=o_date,
                    lesson_num=num,
                    subject=subj,
                    details=f"Преподаватель изменен с '{old_teach_name}' на '{new_teach_name}'",
                    human_message=msg,
                    old_lesson=o,
                    new_lesson=n
                ))
                break

    # 2.3: Замена времени (совпадают: название, аудитория, препод; отличается: время/номер пары)
    for o_idx, o in enumerate(unmatched_old):
        if o_idx in matched_old_indices:
            continue
        o_date = o.get("дата", "")[:10]
        o_subj = _normalize_subject(o.get("дисциплина"))
        o_room = _norm_room(o.get("аудитория"))
        o_teach = _norm_teacher(o.get("преподаватель") or o.get("фиоПреподавателя"))
        o_time = _norm_time(o)

        for n_idx, n in enumerate(unmatched_new):
            if n_idx in matched_new_indices:
                continue
            n_date = n.get("дата", "")[:10]
            # Время может измениться в тот же день (перенос пары на другой слот)
            if o_date != n_date:
                continue

            n_subj = _normalize_subject(n.get("дисциплина"))
            n_room = _norm_room(n.get("аудитория"))
            n_teach = _norm_teacher(n.get("преподаватель") or n.get("фиоПреподавателя"))
            n_time = _norm_time(n)

            if o_subj == n_subj and o_room == n_room and o_teach == n_teach and o_time != n_time:
                matched_old_indices.add(o_idx)
                matched_new_indices.add(n_idx)

                old_time_str = f"{o.get('начало')}-{o.get('конец')}"
                new_time_str = f"{n.get('начало')}-{n.get('конец')}"
                date_fmt = _format_date(n.get("дата", ""))
                old_num = o.get("номерЗанятия", 0)
                new_num = n.get("номерЗанятия", 0)
                subj = _clean_str(n.get("дисциплина"))
                msg = f"{date_fmt}, пара '{subj}': время изменено: {old_time_str} ({old_num}п) -> {new_time_str} ({new_num}п)"

                changes.append(ChangeItem(
                    type="TIME_CHANGED",
                    lesson_id=n.get("код") or o.get("код"),
                    old_lesson_id=o.get("код"),
                    date=n_date,
                    lesson_num=new_num,
                    subject=subj,
                    details=f"Время изменено с {old_time_str} ({old_num}-я пара) на {new_time_str} ({new_num}-я пара)",
                    human_message=msg,
                    old_lesson=o,
                    new_lesson=n
                ))
                break

    # Шаг 3: Оставшиеся несовпавшие старые занятия -> CANCELLED (Пара отменена)
    for o_idx, o in enumerate(unmatched_old):
        if o_idx in matched_old_indices:
            continue
        o_date = o.get("дата", "")[:10]
        date_fmt = _format_date(o.get("дата", ""))
        num = o.get("номерЗанятия", 0)
        subj = _clean_str(o.get("дисциплина"))
        aud = _clean_str(o.get("аудитория"))
        msg = f"{date_fmt}, {num}-я пара ({subj}): пара отменена (была в ауд. {aud})"

        changes.append(ChangeItem(
            type="CANCELLED",
            lesson_id=o.get("код"),
            old_lesson_id=o.get("код"),
            date=o_date,
            lesson_num=num,
            subject=subj,
            details=f"Пара отменена (исчезла из расписания). Ауд: {aud}",
            human_message=msg,
            old_lesson=o,
            new_lesson=None
        ))

    # Шаг 4: Оставшиеся несовпавшие новые занятия -> ADDED (Пара добавлена)
    for n_idx, n in enumerate(unmatched_new):
        if n_idx in matched_new_indices:
            continue
        n_date = n.get("дата", "")[:10]
        date_fmt = _format_date(n.get("дата", ""))
        num = n.get("номерЗанятия", 0)
        subj = _clean_str(n.get("дисциплина"))
        new_aud = _clean_str(n.get("аудитория"))
        new_teacher = _clean_str(n.get("преподаватель") or n.get("фиоПреподавателя"))
        msg = f"{date_fmt}, {num}-я пара ({subj}): добавлена новая пара в ауд. {new_aud}"

        changes.append(ChangeItem(
            type="ADDED",
            lesson_id=n.get("код"),
            old_lesson_id=None,
            date=n_date,
            lesson_num=num,
            subject=subj,
            details=f"Добавлена новая пара. Ауд: {new_aud}, Препод: {new_teacher}",
            human_message=msg,
            old_lesson=None,
            new_lesson=n
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
