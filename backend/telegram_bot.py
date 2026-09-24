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
            [KeyboardButton(text="🗓 Вся неделя"), KeyboardButton(text="⚙️ Моя подписка")],
        ],
        resize_keyboard=True,
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
        type_lesson = (l.get("тип") or l.get("видЗанятия") or "").strip()

        type_emoji = "📘"
        if "лек" in type_lesson.lower():
            type_emoji = "📗 [Лекция]"
        elif "лаб" in type_lesson.lower():
            type_emoji = "🔬 [Лаб]"
        elif "прак" in type_lesson.lower():
            type_emoji = "📙 [Практика]"
        elif type_lesson:
            type_emoji = f"📘 [{type_lesson}]"

        lines.append(f"<b>{num}-я пара</b> ({time_str}):")
        lines.append(f"  {type_emoji} <b>{subj}</b>")
        if aud:
            lines.append(f"  📍 Ауд: <code>{aud}</code>")
        if teacher:
            lines.append(f"  👤 Препод: <i>{teacher}</i>")
        lines.append("")

    return "\n".join(lines).strip()


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
            f"Используйте кнопки ниже для быстрого просмотра расписания:"
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
            f"Вы подписаны на уведомления для ID <code>{s_id}</code> ({group_name}).\n"
            f"Выберите действие на клавиатуре ниже:",
            parse_mode=ParseMode.HTML,
            reply_markup=get_main_keyboard()
        )
    else:
        await message.answer(
            f"👋 Привет, <b>{first_name or 'студент'}</b>!\n\n"
            f"Я бот расписания и уведомлений ДГТУ.\n\n"
            f"Чтобы подключить расписание и моментальные уведомления об отменах и переносах пар:\n"
            f"1️⃣ Нажмите кнопку <b>«Подключить Telegram-уведомления»</b> в мобильном приложении <b>ДГТУ Расписание</b> (иконка 🔔).\n"
            f"2️⃣ Или просто <b>отправьте сюда свой ID студента</b> (например, <code>347338</code>).\n\n"
            f"{ID_HELP_TEXT}",
            parse_mode=ParseMode.HTML,
            disable_web_page_preview=True,
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


@dp.message(F.text == "🗓 Вся неделя")
async def handle_week(message: types.Message):
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
        )
        return

    student_id = sub["student_id"]
    cached = _db.get_schedule(f"student_{student_id}")
    if not cached:
        return

    lessons = extract_lessons(cached["data"])
    now = datetime.now()
    monday = now - timedelta(days=now.weekday())

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
            lines.append(f"  • {num} пара: {subj} (ауд. {aud})")
        blocks.append("\n".join(lines))

    full_text = "🗓 <b>Расписание на текущую неделю:</b>\n\n" + "\n\n".join(blocks)
    keyboard = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📲 Открыть в приложении", url=f"{APP_REDIRECT_URL}?student_id={student_id}")]
    ])
    await message.answer(full_text, parse_mode=ParseMode.HTML, reply_markup=keyboard)


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
        )
        return

    student_id = sub["student_id"]
    cached = _db.get_schedule(f"student_{student_id}")
    group_name = _get_student_group_name(student_id, cached["data"] if cached else None)

    keyboard = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="❌ Отписаться от уведомлений", callback_data="unsubscribe")],
        [InlineKeyboardButton(text="📲 Открыть приложение", url=f"{APP_REDIRECT_URL}?student_id={student_id}")]
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
    )
    await call.answer("Уведомления отключены")


@dp.message(F.text)
async def handle_student_id_input(message: types.Message):
    """Обработка ввода числового ID (например, 347338) или ссылки с edu.donstu.ru (idStudent=347338)."""
    if _db is None or not message.text:
        return
    raw_text = message.text.strip()

    # Извлекаем ID либо из ссылки idStudent=XXXXXX, либо из чистого числа
    match_url = re.search(r"idStudent=(\d{4,8})", raw_text, re.IGNORECASE)
    if match_url:
        student_id = match_url.group(1)
    elif re.match(r"^\d{4,8}$", raw_text):
        student_id = raw_text
    else:
        await message.answer(
            f"🤔 Я не распознал команду или ID студента.\n"
            f"Пожалуйста, отправьте ваш 6-значный <b>ID студента</b> (только цифры, например <code>347338</code>) "
            f"или ссылку экспорта с сайта ДГТУ.\n\n"
            f"{ID_HELP_TEXT}",
            parse_mode=ParseMode.HTML,
            disable_web_page_preview=True,
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
        f"Уведомления об изменениях расписания будут приходить сюда моментально!",
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
