"""
Telegram-бот для уведомлений и просмотра расписания ДГТУ.
Поддерживает:
- Deep Linking: /start <student_id> (авто-привязка из мобильного приложения)
- Текстовый просмотр расписания: Сегодня, Завтра, Вся неделя
- Мгновенные уведомления об отменах, заменах, переносах пар и смене аудиторий
- Inline-кнопку «Открыть в приложении» под каждым уведомлением
"""

import os
import re
import logging
import asyncio
from datetime import datetime, timedelta
from typing import List, Dict, Any, Optional

from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command, CommandStart, CommandObject
from aiogram.types import (
    ReplyKeyboardMarkup,
    KeyboardButton,
    InlineKeyboardMarkup,
    InlineKeyboardButton,
)
from aiogram.enums import ParseMode

from database import Database
from fetcher import fetch_schedule
from diff_engine import _format_date, extract_lessons

logger = logging.getLogger("DSTU_Telegram_Bot")

def _load_env_file():
    """Загружает переменные из .env файла рядом со скриптом, если они не заданы в окружении."""
    env_file = os.path.join(os.path.dirname(__file__), ".env")
    if os.path.exists(env_file):
        try:
            with open(env_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        os.environ.setdefault(k.strip(), v.strip())
        except Exception:
            pass

_load_env_file()

BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
APP_REDIRECT_URL = os.getenv("APP_REDIRECT_URL", "http://localhost:8000/app")
APK_DOWNLOAD_URL = os.getenv(
    "APK_DOWNLOAD_URL",
    APP_REDIRECT_URL.replace("/app", "/download/DSTU-schedule.apk"),
)

bot = Bot(token=BOT_TOKEN) if BOT_TOKEN else None
dp = Dispatcher()

# Глобальная ссылка на БД (инициализируется при старте сервера)
_db: Optional[Database] = None

def set_database(database: Database):
    global _db
    _db = database


def get_main_keyboard() -> ReplyKeyboardMarkup:
    """Главная клавиатура бота."""
    return ReplyKeyboardMarkup(
        keyboard=[
            [KeyboardButton(text="📅 Сегодня"), KeyboardButton(text="📆 Завтра")],
            [KeyboardButton(text="🗓 Текущая неделя"), KeyboardButton(text="🗓 Следующая неделя")],
            [KeyboardButton(text="⚙️ Моя подписка")],
        ],
        resize_keyboard=True,
    )


def get_apk_download_keyboard() -> InlineKeyboardMarkup:
    """Inline-кнопка для прямого скачивания APK-файла приложения."""
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [InlineKeyboardButton(text="📥 Скачать приложение (.APK)", url=APK_DOWNLOAD_URL)]
        ]
    )


def _get_student_group_name(student_id: int | str, cached_data: Optional[Dict[str, Any]] = None) -> str:
    """Извлекает академическую группу студента из кэша или ДГТУ."""
    if cached_data:
        info = cached_data.get("data", {}).get("info", {})
        group = info.get("group", {}).get("name")
        if group:
            return group
    try:
        res = fetch_schedule(student_id)
        if res.success and res.data:
            info = res.data.get("data", {}).get("info", {})
            group = info.get("group", {}).get("name")
            if group:
                return group
    except Exception:
        pass
    return "Студент"


def _detect_lesson_type(l: Dict[str, Any]) -> str:
    """Определяет тип занятия (Лекция, Практика, Лабораторная и т.д.) аналогично мобильному приложению."""
    s = (l.get("дисциплина") or "").strip()
    s_low = s.lower()
    t = (l.get("тема") or "").strip().lower()
    c = (l.get("цвет") or "").strip().lower()

    m = re.match(r"^(лек|пр|лаб|сем|зач|экз|конс|кп|кр)[\.\s]+", s, re.IGNORECASE)
    if m:
        p = m.group(1).lower()
        return {
            "лек": "Лекция",
            "пр": "Практика",
            "лаб": "Лабораторная",
            "сем": "Семинар",
            "зач": "Зачет",
            "экз": "Экзамен",
            "конс": "Консультация",
        }.get(p, "Практика")

    if re.search(r"(?:^|[\s,.;:()])(лекция|лекц\.|лек\.)(?:$|[\s,.;:()0-9])", t) or re.match(r"^тема\s*\d+", t):
        return "Лекция"
    if re.search(r"(?:^|[\s,.;:()])(практика|практическое|практикум|пр\.|кср)(?:$|[\s,.;:()0-9])", t):
        return "Практика"
    if "лаборатор" in t or t.startswith("лаб"):
        return "Лабораторная"
    if "семинар" in t:
        return "Семинар"
    if t.startswith("зачет") or t.startswith("зачёт") or t == "зачет":
        return "Зачет"
    if t.startswith("экзамен") or t == "экзамен":
        return "Экзамен"
    if t.startswith("защита") or t.startswith("предзащита") or t.startswith("открытая защита"):
        return "Защита"
    if t.startswith("консультация") or s_low.startswith("консультация"):
        return "Консультация"

    if "профильный проект" in s_low:
        return "Практика"

    if any(
        k in t
        for k in (
            "работа над",
            "работа с",
            "работа по",
            "кейс",
            "воркшоп",
            "мастер-слайд",
            "мастер-класс",
            "плейтест",
            "разработка",
            "сборка",
            "моделирование",
            "расчет",
            "расчёт",
            "решение задач",
            "поиск и анализ",
            "пакет конкурсной",
        )
    ):
        return "Практика"

    if c in ("#4caf50", "#008000"):
        return "Лекция"
    if c in ("#5c6bc0", "#2196f3", "#009688", "#ff9800", "#ab47bc", "#fdd017", "#44c8c8"):
        return "Практика"
    if c == "#004c3e":
        return "Лабораторная"
    if c == "#ef5350":
        return "Зачет"

    if t and any(
        t.startswith(k)
        for k in (
            "введение",
            "основы",
            "теория",
            "история",
            "архитектура",
            "проектная документация",
            "отчеты о нир",
            "оформление научных",
            "визуализация результатов",
            "принципы",
            "методология",
            "современные тренды",
            "проблемы защиты",
            "особенности реализации",
            "обучение с подкреплением",
            "процедурная генерация",
        )
    ):
        return "Лекция"

    return "Практика"


def _format_day_schedule(lessons: List[Dict[str, Any]], title_date: str) -> str:
    """Форматирует расписание на один день в виде красивого текста для Telegram."""
    if not lessons:
        return f"📅 <b>Расписание на {title_date}:</b>\n\n🎉 <i>Пар нет! Можно отдыхать.</i>"

    # Сортируем пары по номеру
    lessons_sorted = sorted(lessons, key=lambda x: x.get("номерЗанятия", 0))

    lines = [f"📅 <b>Расписание на {title_date}:</b>\n"]
    for l in lessons_sorted:
        num = l.get("номерЗанятия", "?")
        time_start = l.get("начало", "")
        time_end = l.get("конец", "")
        time_str = f"{time_start} - {time_end}" if time_start else ""
        subj = l.get("дисциплина", "Занятие").strip()
        aud = l.get("аудитория", "").strip()
        teacher = (l.get("преподаватель") or l.get("фиоПреподавателя") or "").strip()
        type_lesson = _detect_lesson_type(l)

        type_emoji = "📘"
        if "лек" in type_lesson.lower():
            type_emoji = "📗 [Лекция]"
        elif "лаб" in type_lesson.lower():
            type_emoji = "🔬 [Лаб]"
        elif "прак" in type_lesson.lower():
            type_emoji = "📙 [Практика]"
        else:
            type_emoji = f"📘 [{type_lesson}]"

        lines.append(f"<b>{num}-я пара</b> ({time_str}):")
        lines.append(f"  {type_emoji} <b>{subj}</b>")
        if aud:
            lines.append(f"  📍 Ауд: <code>{aud}</code>")
        if teacher:
            lines.append(f"  👤 Препод: <i>{teacher}</i>")
        lines.append("")

    return "\n".join(lines).strip()


def _format_week_schedule(lessons: List[Dict[str, Any]], week_offset: int = 0) -> str:
    """Форматирует расписание на неделю (пн-сб) со смещением week_offset относительно текущей недели."""
    now = datetime.now()
    monday = (now - timedelta(days=now.weekday())) + timedelta(weeks=week_offset)
    saturday = monday + timedelta(days=5)

    blocks = []
    days_ru = ["Понедельник", "Вторник", "Среда", "Четверг", "Пятница", "Суббота"]

    for i in range(6):
        day_dt = monday + timedelta(days=i)
        day_str = day_dt.strftime("%Y-%m-%d")
        day_lessons = [l for l in lessons if l.get("дата", "").startswith(day_str)]
        day_title = f"{days_ru[i]} ({day_dt.day} {_format_date(day_str).split()[1]})"

        if not day_lessons:
            blocks.append(f"<b>{day_title}</b>: <i>Пар нет</i>")
            continue

        day_lessons_sorted = sorted(day_lessons, key=lambda x: x.get("номерЗанятия", 0))
        lines = [f"<b>{day_title}</b>:"]
        for l in day_lessons_sorted:
            num = l.get("номерЗанятия", "?")
            subj = l.get("дисциплина", "").strip()
            aud = l.get("аудитория", "").strip()
            type_lesson = _detect_lesson_type(l)
            type_short = "лк" if "лек" in type_lesson.lower() else ("лаб" if "лаб" in type_lesson.lower() else "пр")
            aud_str = f"ауд. {aud}" if aud else ""
            lines.append(f"  • {num} пара [{type_short}]: {subj} {f'({aud_str})' if aud_str else ''}")
        blocks.append("\n".join(lines))

    if week_offset == 0:
        header = f"🗓 <b>Расписание на текущую неделю ({monday.strftime('%d.%m')} – {saturday.strftime('%d.%m')}):</b>"
    elif week_offset == 1:
        header = f"🗓 <b>Расписание на следующую неделю ({monday.strftime('%d.%m')} – {saturday.strftime('%d.%m')}):</b>"
    elif week_offset == -1:
        header = f"🗓 <b>Расписание на прошлую неделю ({monday.strftime('%d.%m')} – {saturday.strftime('%d.%m')}):</b>"
    else:
        header = f"🗓 <b>Расписание на неделю ({monday.strftime('%d.%m')} – {saturday.strftime('%d.%m')}):</b>"

    return header + "\n\n" + "\n\n".join(blocks)


def get_week_inline_keyboard(student_id: str, week_offset: int = 0) -> InlineKeyboardMarkup:
    """Генерирует инлайн-кнопки перелистывания недель (⬅️ / ➡️) и ссылку на приложение."""
    prev_offset = week_offset - 1
    next_offset = week_offset + 1

    nav_row = [
        InlineKeyboardButton(text="⬅️ Пред. неделя", callback_data=f"week:{prev_offset}:{student_id}")
    ]
    if week_offset != 0:
        nav_row.append(InlineKeyboardButton(text="🗓 Текущая", callback_data=f"week:0:{student_id}"))
    nav_row.append(InlineKeyboardButton(text="➡️ След. неделя", callback_data=f"week:{next_offset}:{student_id}"))

    return InlineKeyboardMarkup(
        inline_keyboard=[
            nav_row,
            [InlineKeyboardButton(text="📲 Открыть в приложении", url=f"{APP_REDIRECT_URL}?student_id={student_id}")],
        ]
    )


MONTHS_RU_MAP = {
    "янв": 1, "января": 1, "январь": 1,
    "фев": 2, "февраля": 2, "февраль": 2,
    "мар": 3, "марта": 3, "март": 3,
    "апр": 4, "апреля": 4, "апрель": 4,
    "май": 5, "мая": 5,
    "июн": 6, "июня": 6, "июнь": 6,
    "июл": 7, "июля": 7, "июль": 7,
    "авг": 8, "августа": 8, "август": 8,
    "сен": 9, "сентября": 9, "сентябрь": 9,
    "окт": 10, "октября": 10, "октябрь": 10,
    "ноя": 11, "ноября": 11, "ноябрь": 11,
    "дек": 12, "декабря": 12, "декабрь": 12,
}


def _safe_date(year: int, month: int, day: int) -> Optional[datetime]:
    try:
        return datetime(year, month, day)
    except ValueError:
        return None


def parse_date_query(raw_text: str) -> Optional[datetime]:
    """
    Распознает дату в сообщении пользователя:
    - Число месяца от 1 до 31 ('28', '5', '05'). Если число уже прошло в текущем месяце — берет следующий месяц.
    - Дата в формате ДД.ММ или ДД.ММ.ГГГГ ('28.09', '28/09', '28.09.2026').
    - Дата с русским названием месяца ('28 сентября', '5 окт', '12 мая 2026').
    - Фразы с префиксами: 'пары на 28', 'расписание 5', 'на 29 число'.
    """
    text = raw_text.strip().lower()

    # Срезаем типовые вводные слова и приставки
    prefixes = [
        "расписание на", "расписание", "пары на", "пары", "пара на", "пара",
        "занятия на", "занятия", "уроки на", "уроки", "на"
    ]
    for p in prefixes:
        if text.startswith(p + " "):
            text = text[len(p):].strip()
            break

    # Срезаем суффиксы «число», «числа»
    text = re.sub(r"\s+числ[оа]$", "", text).strip()

    now = datetime.now()

    # 1. Формат: число + название месяца (например "28 сентября", "5 окт", "12 мая 2026")
    m_text = re.match(r"^0?([1-9]|[12]\d|3[01])\s+([а-яё]+)(?:\s+(\d{2,4}))?$", text)
    if m_text:
        day = int(m_text.group(1))
        m_str = m_text.group(2)
        year_str = m_text.group(3)
        month = None
        for k, v in MONTHS_RU_MAP.items():
            if m_str.startswith(k):
                month = v
                break
        if month:
            if year_str:
                year = int(year_str)
                if year < 100:
                    year += 2000
            else:
                year = now.year if month >= now.month else now.year + 1
            dt = _safe_date(year, month, day)
            if dt:
                return dt

    # 2. Формат: ДД.ММ или ДД.ММ.ГГГГ (через точку, слэш или дефис)
    m_dot = re.match(r"^0?([1-9]|[12]\d|3[01])[./-]0?([1-9]|1[012])(?:[./-](\d{2,4}))?$", text)
    if m_dot:
        day = int(m_dot.group(1))
        month = int(m_dot.group(2))
        year_str = m_dot.group(3)
        if year_str:
            year = int(year_str)
            if year < 100:
                year += 2000
        else:
            year = now.year if month >= now.month else now.year + 1
        dt = _safe_date(year, month, day)
        if dt:
            return dt

    # 3. Число месяца: от 1 до 31 (например "28", "5", "05")
    m_num = re.match(r"^0?([1-9]|[12]\d|3[01])$", text)
    if m_num:
        day = int(m_num.group(1))
        if day >= now.day:
            dt = _safe_date(now.year, now.month, day)
            if dt:
                return dt
            # Если в текущем месяце нет такого дня (например 31 сентября), переходим к следующему
            next_m = now.month + 1
            next_y = now.year
            if next_m > 12:
                next_m = 1
                next_y += 1
            return _safe_date(next_y, next_m, day)
        else:
            # Число уже прошло в текущем месяце -> берем следующий месяц
            next_m = now.month + 1
            next_y = now.year
            if next_m > 12:
                next_m = 1
                next_y += 1
            dt = _safe_date(next_y, next_m, day)
            if dt:
                return dt
            return _safe_date(now.year, now.month, day)

    return None



ID_HELP_TEXT = (
    "❓ <b>Где найти свой ID студента?</b>\n"
    "1. Перейдите на сайт <a href=\"https://edu.donstu.ru\">edu.donstu.ru</a>\n"
    "2. Откройте раздел <b>«Расписание»</b>\n"
    "3. На странице расписания нажмите кнопку <b>«Экспорт»</b> → скопируйте ссылку: "
    "параметр <code>idStudent=XXXXXX</code> — это и есть ваш 6-значный код "
    "(можно отправить боту как сам код, так и всю ссылку целиком)."
)


@dp.message(CommandStart())
async def handle_start(message: types.Message, command: CommandObject):
    """
    Обработка /start и Deep Linking: /start <student_id>.
    Студент переходит из мобильного приложения по ссылке https://t.me/bot?start=347338.
    """
    if _db is None:
        await message.answer("⚠️ Сервер базы данных инициализируется, повторите через минуту.")
        return

    student_id_arg = (command.args or "").strip()
    chat_id = message.chat.id
    username = message.from_user.username
    first_name = message.from_user.first_name

    if student_id_arg.isdigit():
        # Студент пришел по ссылке из мобилки или ввел ID
        student_id = student_id_arg
        cached = _db.get_schedule(f"student_{student_id}")

        # Если расписания студента еще нет в базе, загружаем
        if not cached:
            loop = asyncio.get_running_loop()
            res = await loop.run_in_executor(None, fetch_schedule, student_id)
            if res.success and res.data:
                _db.save_schedule(f"student_{student_id}", "student", res.data, res.upload_date)
                cached = _db.get_schedule(f"student_{student_id}")

        group_name = _get_student_group_name(student_id, cached["data"] if cached else None)
        _db.subscribe_telegram(chat_id, student_id, username, first_name)

        welcome_text = (
            f"🎓 <b>Добро пожаловать в бота расписания ДГТУ!</b>\n\n"
            f"✅ <b>Вы успешно подписаны на обновления:</b>\n"
            f"• <b>ID студента:</b> <code>{student_id}</code>\n"
            f"• <b>Группа:</b> <b>{group_name}</b>\n\n"
            f"🔔 Теперь при любых отменах, переносах пар или сменах аудиторий бот пришлет вам моментальное сообщение со звуком!\n\n"
            f"💡 <b>Как смотреть пары:</b>\n"
            f"• Кнопки меню внизу: <b>Сегодня</b>, <b>Завтра</b>, <b>Текущая</b> и <b>Следующая неделя</b>\n"
            f"• Или просто <b>напишите число</b> (например, <code>28</code> или <code>05.10</code>), чтобы узнать пары на этот день."
        )
        await message.answer(welcome_text, parse_mode=ParseMode.HTML, reply_markup=get_main_keyboard())
        return

    # Если аргументов нет — проверяем, подписан ли уже
    existing = _db.get_telegram_subscriber(chat_id)
    if existing and existing.get("is_active"):
        s_id = existing["student_id"]
        cached = _db.get_schedule(f"student_{s_id}")
        group_name = _get_student_group_name(s_id, cached["data"] if cached else None)
        await message.answer(
            f"👋 С возвращением, <b>{first_name or 'студент'}</b>!\n\n"
            f"Вы подписаны на уведомления для ID <code>{s_id}</code> ({group_name}).\n\n"
            f"💡 <i>Отправьте число (например, <code>28</code> или <code>05.10</code>) или используйте кнопки внизу:</i>",
            parse_mode=ParseMode.HTML,
            reply_markup=get_main_keyboard()
        )
    else:
        await message.answer(
            f"👋 Привет, <b>{first_name or 'студент'}</b>!\n\n"
            f"Я бот расписания и уведомлений ДГТУ.\n\n"
            f"Чтобы подключить расписание и моментальные уведомления об отменах и переносах пар:\n"
            f"1️⃣ Нажмите кнопку <b>«Подключить Telegram-уведомления»</b> в мобильном приложении "
            f"<a href=\"{APK_DOWNLOAD_URL}\"><b>ДГТУ Расписание (скачать .APK)</b></a> (иконка 🔔).\n"
            f"2️⃣ Или просто <b>отправьте сюда свой ID студента</b> (например, <code>347338</code>).\n\n"
            f"{ID_HELP_TEXT}",
            parse_mode=ParseMode.HTML,
            disable_web_page_preview=True,
            reply_markup=get_apk_download_keyboard(),
        )


@dp.message(F.text == "📅 Сегодня")
async def handle_today(message: types.Message):
    if _db is None:
        return
    sub = _db.get_telegram_subscriber(message.chat.id)
    if not sub or not sub.get("is_active"):
        await message.answer(
            f"⚠️ Вы еще не указали свой ID студента.\n"
            f"Отправьте свой 6-значный ID (например, <code>347338</code>).\n\n"
            f"{ID_HELP_TEXT}",
            parse_mode=ParseMode.HTML,
            disable_web_page_preview=True,
            reply_markup=get_apk_download_keyboard(),
        )
        return

    student_id = sub["student_id"]
    cached = _db.get_schedule(f"student_{student_id}")
    if not cached:
        loop = asyncio.get_running_loop()
        res = await loop.run_in_executor(None, fetch_schedule, student_id)
        if res.success:
            _db.save_schedule(f"student_{student_id}", "student", res.data, res.upload_date)
            cached = _db.get_schedule(f"student_{student_id}")

    if not cached:
        await message.answer("Не удалось загрузить расписание. Попробуйте позже.")
        return

    lessons = extract_lessons(cached["data"])
    today_str = datetime.now().strftime("%Y-%m-%d")
    today_formatted = _format_date(today_str)

    today_lessons = [l for l in lessons if l.get("дата", "").startswith(today_str)]
    text = _format_day_schedule(today_lessons, today_formatted)

    keyboard = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📲 Открыть в приложении", url=f"{APP_REDIRECT_URL}?student_id={student_id}&date={today_str}")]
    ])
    await message.answer(text, parse_mode=ParseMode.HTML, reply_markup=keyboard)


@dp.message(F.text == "📆 Завтра")
async def handle_tomorrow(message: types.Message):
    if _db is None:
        return
    sub = _db.get_telegram_subscriber(message.chat.id)
    if not sub or not sub.get("is_active"):
        await message.answer(
            f"⚠️ Вы еще не указали свой ID студента.\n"
            f"Отправьте свой 6-значный ID (например, <code>347338</code>).\n\n"
            f"{ID_HELP_TEXT}",
            parse_mode=ParseMode.HTML,
            disable_web_page_preview=True,
            reply_markup=get_apk_download_keyboard(),
        )
        return

    student_id = sub["student_id"]
    cached = _db.get_schedule(f"student_{student_id}")
    if not cached:
        return

    lessons = extract_lessons(cached["data"])
    tomorrow_dt = datetime.now() + timedelta(days=1)
    tomorrow_str = tomorrow_dt.strftime("%Y-%m-%d")
    tomorrow_formatted = _format_date(tomorrow_str)

    tomorrow_lessons = [l for l in lessons if l.get("дата", "").startswith(tomorrow_str)]
    text = _format_day_schedule(tomorrow_lessons, tomorrow_formatted)

    keyboard = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📲 Открыть в приложении", url=f"{APP_REDIRECT_URL}?student_id={student_id}&date={tomorrow_str}")]
    ])
    await message.answer(text, parse_mode=ParseMode.HTML, reply_markup=keyboard)


async def _show_week_schedule(message: types.Message, week_offset: int = 0):
    if _db is None:
        return
    sub = _db.get_telegram_subscriber(message.chat.id)
    if not sub or not sub.get("is_active"):
        await message.answer(
            f"⚠️ Вы еще не указали свой ID студента.\n"
            f"Отправьте свой 6-значный ID (например, <code>347338</code>).\n\n"
            f"{ID_HELP_TEXT}",
            parse_mode=ParseMode.HTML,
            disable_web_page_preview=True,
            reply_markup=get_apk_download_keyboard(),
        )
        return

    student_id = sub["student_id"]
    cached = _db.get_schedule(f"student_{student_id}")
    if not cached:
        loop = asyncio.get_running_loop()
        res = await loop.run_in_executor(None, fetch_schedule, student_id)
        if res.success and res.data:
            _db.save_schedule(f"student_{student_id}", "student", res.data, res.upload_date)
            cached = _db.get_schedule(f"student_{student_id}")

    if not cached:
        await message.answer("Не удалось загрузить расписание. Попробуйте позже.")
        return

    lessons = extract_lessons(cached["data"])
    full_text = _format_week_schedule(lessons, week_offset=week_offset)
    keyboard = get_week_inline_keyboard(student_id, week_offset=week_offset)
    await message.answer(full_text, parse_mode=ParseMode.HTML, reply_markup=keyboard)


@dp.message(F.text.in_({"🗓 Вся неделя", "🗓 Текущая неделя", "текущая неделя", "вся неделя", "эта неделя"}))
async def handle_current_week(message: types.Message):
    await _show_week_schedule(message, week_offset=0)


@dp.message(F.text.in_({"🗓 Следующая неделя", "🗓 След. неделя", "следующая неделя", "след неделя", "след. неделя"}))
async def handle_next_week(message: types.Message):
    await _show_week_schedule(message, week_offset=1)


@dp.callback_query(F.data.startswith("week:"))
async def handle_callback_week(call: types.CallbackQuery):
    if _db is None:
        await call.answer()
        return
    parts = call.data.split(":")
    if len(parts) < 3:
        await call.answer()
        return
    try:
        week_offset = int(parts[1])
        student_id = parts[2]
    except ValueError:
        await call.answer()
        return

    cached = _db.get_schedule(f"student_{student_id}")
    if not cached:
        loop = asyncio.get_running_loop()
        res = await loop.run_in_executor(None, fetch_schedule, student_id)
        if res.success and res.data:
            _db.save_schedule(f"student_{student_id}", "student", res.data, res.upload_date)
            cached = _db.get_schedule(f"student_{student_id}")

    if not cached:
        await call.answer("Расписание не найдено в кэше", show_alert=True)
        return

    lessons = extract_lessons(cached["data"])
    text = _format_week_schedule(lessons, week_offset=week_offset)
    keyboard = get_week_inline_keyboard(student_id, week_offset=week_offset)

    try:
        await call.message.edit_text(text, parse_mode=ParseMode.HTML, reply_markup=keyboard)
    except Exception:
        pass
    await call.answer()


@dp.message(F.text == "⚙️ Моя подписка")
async def handle_subscription_info(message: types.Message):
    if _db is None:
        return
    sub = _db.get_telegram_subscriber(message.chat.id)
    if not sub or not sub.get("is_active"):
        await message.answer(
            f"У вас нет активной подписки.\n"
            f"Отправьте свой 6-значный ID студента (например, <code>347338</code>).\n\n"
            f"{ID_HELP_TEXT}",
            parse_mode=ParseMode.HTML,
            disable_web_page_preview=True,
            reply_markup=get_apk_download_keyboard(),
        )
        return

    student_id = sub["student_id"]
    cached = _db.get_schedule(f"student_{student_id}")
    group_name = _get_student_group_name(student_id, cached["data"] if cached else None)

    keyboard = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📲 Открыть приложение", url=f"{APP_REDIRECT_URL}?student_id={student_id}")],
        [InlineKeyboardButton(text="📥 Скачать приложение (.APK)", url=APK_DOWNLOAD_URL)],
        [InlineKeyboardButton(text="❌ Отписаться от уведомлений", callback_data="unsubscribe")],
    ])

    text = (
        f"⚙️ <b>Параметры вашей подписки:</b>\n\n"
        f"• <b>ID студента:</b> <code>{student_id}</code>\n"
        f"• <b>Академическая группа:</b> <b>{group_name}</b>\n"
        f"• <b>Статус:</b> 🟢 Активна (пуши включены)\n\n"
        f"Чтобы переключиться на другого студента, просто отправьте сюда новый ID.\n\n"
        f"{ID_HELP_TEXT}"
    )
    await message.answer(text, parse_mode=ParseMode.HTML, reply_markup=keyboard, disable_web_page_preview=True)


@dp.callback_query(F.data == "unsubscribe")
async def handle_callback_unsubscribe(call: types.CallbackQuery):
    if _db is None:
        return
    _db.unsubscribe_telegram(call.message.chat.id)
    await call.message.edit_text(
        f"❌ <b>Вы отписались от уведомлений.</b>\n\n"
        f"Чтобы снова включить их, отправьте свой ID студента или команду /start.\n\n"
        f"{ID_HELP_TEXT}",
        parse_mode=ParseMode.HTML,
        disable_web_page_preview=True,
        reply_markup=get_apk_download_keyboard(),
    )
    await call.answer("Уведомления отключены")


@dp.message(F.text)
async def handle_text_input(message: types.Message):
    """
    Универсальный обработчик текстовых сообщений:
    1. Просмотр пар по числу/дате ('28', '5', '05', '28.09', '5 октября').
    2. Привязка ID студента ('347338' или ссылка экспорта).
    """
    if _db is None or not message.text:
        return
    raw_text = message.text.strip()

    # 1. Проверяем, ввел ли пользователь число или дату
    target_dt = parse_date_query(raw_text)
    if target_dt:
        chat_id = message.chat.id
        sub = _db.get_telegram_subscriber(chat_id)
        target_str = target_dt.strftime("%Y-%m-%d")
        target_formatted = _format_date(target_str)

        if not sub or not sub.get("is_active"):
            await message.answer(
                f"📅 Вы запросили расписание на <b>{target_formatted}</b>.\n\n"
                f"⚠️ Чтобы просматривать расписание, сначала отправьте свой 6-значный <b>ID студента</b> "
                f"(например, <code>347338</code>) или ссылку экспорта с сайта ДГТУ.\n\n"
                f"{ID_HELP_TEXT}",
                parse_mode=ParseMode.HTML,
                disable_web_page_preview=True,
                reply_markup=get_apk_download_keyboard(),
            )
            return

        student_id = sub["student_id"]
        cached = _db.get_schedule(f"student_{student_id}")
        if not cached:
            loop = asyncio.get_running_loop()
            res = await loop.run_in_executor(None, fetch_schedule, student_id)
            if res.success and res.data:
                _db.save_schedule(f"student_{student_id}", "student", res.data, res.upload_date)
                cached = _db.get_schedule(f"student_{student_id}")

        if not cached:
            await message.answer("Не удалось загрузить расписание. Попробуйте позже.")
            return

        lessons = extract_lessons(cached["data"])
        day_lessons = [l for l in lessons if l.get("дата", "").startswith(target_str)]
        text = _format_day_schedule(day_lessons, target_formatted)

        keyboard = InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(
                text="📲 Открыть в приложении",
                url=f"{APP_REDIRECT_URL}?student_id={student_id}&date={target_str}"
            )]
        ])
        await message.answer(text, parse_mode=ParseMode.HTML, reply_markup=keyboard)
        return

    # 2. Проверяем ввод ID студента (4-8 цифр или idStudent=XXXXXX)
    match_url = re.search(r"idStudent=(\d{4,8})", raw_text, re.IGNORECASE)
    if match_url:
        student_id = match_url.group(1)
    elif re.match(r"^\d{4,8}$", raw_text):
        student_id = raw_text
    else:
        await message.answer(
            f"🤔 Я не распознал команду или число.\n\n"
            f"💡 <b>Вы можете:</b>\n"
            f"• Написать <b>число</b> (например, <code>28</code>, <code>5</code>, <code>28.09</code> или <code>5 октября</code>) — покажу пары на этот день.\n"
            f"• Нажать кнопки в меню: <b>Сегодня</b>, <b>Завтра</b>, <b>Текущая неделя</b>, <b>Следующая неделя</b>.\n"
            f"• Отправить 6-значный <b>ID студента</b> (например, <code>347338</code>) для привязки расписания.\n\n"
            f"{ID_HELP_TEXT}",
            parse_mode=ParseMode.HTML,
            disable_web_page_preview=True,
            reply_markup=get_apk_download_keyboard(),
        )
        return

    chat_id = message.chat.id
    username = message.from_user.username
    first_name = message.from_user.first_name

    cached = _db.get_schedule(f"student_{student_id}")
    if not cached:
        loop = asyncio.get_running_loop()
        res = await loop.run_in_executor(None, fetch_schedule, student_id)
        if res.success and res.data:
            _db.save_schedule(f"student_{student_id}", "student", res.data, res.upload_date)
            cached = _db.get_schedule(f"student_{student_id}")

    group_name = _get_student_group_name(student_id, cached["data"] if cached else None)

    _db.subscribe_telegram(chat_id, student_id, username, first_name)

    await message.answer(
        f"✅ <b>ID успешно подключен!</b>\n\n"
        f"• <b>ID студента:</b> <code>{student_id}</code>\n"
        f"• <b>Группа:</b> <b>{group_name}</b>\n\n"
        f"Уведомления об изменениях расписания будут приходить сюда моментально!\n\n"
        f"Используйте кнопки меню или напишите число для просмотра пар.",
        parse_mode=ParseMode.HTML,
        reply_markup=get_main_keyboard()
    )


async def broadcast_schedule_changes(target_id: str, changes: List[Dict[str, Any]]):
    """
    Рассылает сообщения об обнаруженных изменениях в расписании всем подписчикам Telegram.
    Вызывается бэкендом (APScheduler или sync_target) при выявлении диффов.
    """
    if not changes or _db is None or bot is None:
        return

    subscribers = _db.get_telegram_subscribers(target_id)
    if not subscribers:
        logger.info(f"Нет Telegram-подписчиков для {target_id}")
        return

    clean_id = target_id.replace("student_", "")
    cached = _db.get_schedule(target_id)
    group_name = _get_student_group_name(clean_id, cached["data"] if cached else None)

    # Группируем изменения по дате
    dates = sorted(list(set(ch.get("date", "") for ch in changes)))
    first_date = dates[0] if dates else datetime.now().strftime("%Y-%m-%d")

    lines = [
        "🚨 <b>ВНИМАНИЕ! ИЗМЕНЕНИЯ В РАСПИСАНИИ ДГТУ</b>",
        f"Группа: <b>{group_name}</b>\n"
    ]

    for ch in changes:
        ch_type = ch.get("type", "")
        human_msg = ch.get("human_message") or ch.get("details", "")
        subj = ch.get("subject", "Занятие")
        num = ch.get("lesson_num", "")
        date_str = _format_date(ch.get("date", ""))

        if ch_type == "CANCELLED":
            lines.append(f"🚫 <b>ПАРА ОТМЕНЕНА:</b> {subj}")
            lines.append(f"   📅 {date_str}, {num}-я пара")
            if ch.get("details"):
                lines.append(f"   ℹ️ <i>{ch['details']}</i>")
        elif ch_type == "ROOM_CHANGED":
            lines.append(f"🔄 <b>СМЕНА АУДИТОРИИ:</b> {subj}")
            lines.append(f"   📅 {date_str}, {num}-я пара")
            lines.append(f"   📍 <i>{human_msg.split('): ')[-1] if '): ' in human_msg else human_msg}</i>")
        elif ch_type in ("ADDED", "NEW"):
            lines.append(f"➕ <b>ДОБАВЛЕНА ПАРА:</b> {subj}")
            lines.append(f"   📅 {date_str}, {num}-я пара")
            if ch.get("details"):
                lines.append(f"   ℹ️ <i>{ch['details']}</i>")
        else:
            lines.append(f"ℹ️ <b>ИЗМЕНЕНИЕ:</b> {subj} ({date_str}, {num}-я пара)")
            lines.append(f"   <i>{human_msg}</i>")
        lines.append("")

    message_text = "\n".join(lines).strip()

    # Кнопка для быстрого открытия мобильного приложения
    keyboard = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(
            text="📲 Открыть в приложении", 
            url=f"{APP_REDIRECT_URL}?student_id={clean_id}&date={first_date}"
        )]
    ])

    logger.info(f"Рассылка {len(changes)} изменений для {target_id} {len(subscribers)} подписчикам Telegram...")

    for sub in subscribers:
        chat_id = sub["chat_id"]
        try:
            await bot.send_message(
                chat_id=chat_id,
                text=message_text,
                parse_mode=ParseMode.HTML,
                reply_markup=keyboard
            )
            logger.info(f"Уведомление успешно доставлено в Telegram chat {chat_id}")
        except Exception as e:
            logger.error(f"Не удалось отправить уведомление в chat {chat_id}: {e}")
            if "bot was blocked by the user" in str(e).lower() or "user is deactivated" in str(e).lower():
                _db.unsubscribe_telegram(chat_id)


async def start_bot_polling():
    """Запускает long polling Telegram-бота в фоновой задаче asyncio."""
    if bot is None:
        logger.warning("TELEGRAM_BOT_TOKEN не задан! Запуск Telegram-бота пропущен.")
        return

    logger.info("Запуск Telegram-бота (@dstu_schedule_notify_bot)...")
    try:
        # Удаляем предыдущий webhook, если был установлен
        await bot.delete_webhook(drop_pending_updates=True)
        await dp.start_polling(bot)
    except asyncio.CancelledError:
        logger.info("Telegram-бот остановлен.")
    except Exception as e:
        logger.error(f"Ошибка в работе Telegram-бота: {e}")
    finally:
        await bot.session.close()
