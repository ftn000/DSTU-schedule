"""
REST API сервер на FastAPI с интегрированным фоновым планировщиком (APScheduler).

Функционал:
1. Выдача расписания для мобильного приложения (с защитой от сбоев ДГТУ и кэшем).
2. Выдача истории изменений (отмен, переносов) для студента.
3. Регистрация устройств для push-уведомлений.
4. Фоновый опрос API ДГТУ по расписанию (раз в 30-60 минут) с выявлением диффов.
"""

import sys
import logging
import asyncio
from typing import Optional, List, Dict, Any
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from apscheduler.schedulers.asyncio import AsyncIOScheduler

from database import Database
from fetcher import fetch_schedule
from diff_engine import compare_schedules, format_push_notification, extract_lessons
from telegram_bot import start_bot_polling, set_database, broadcast_schedule_changes


# Настройка логирования
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("DSTU_Schedule_Server")

# Инициализация базы данных
db = Database("schedule.db")

# Фоновый планировщик
scheduler = AsyncIOScheduler()


class SubscriptionRequest(BaseModel):
    device_token: str
    student_id: int | str


async def sync_target(target_id: str, student_id: int | str):
    """Синхронизирует одного студента: скачивает, сравнивает и сохраняет."""
    logger.info(f"Фоновая проверка расписания для {target_id}...")
    
    # Загружаем из ДГТУ
    # Запускаем в отдельном потоке, так как urllib синхронный
    loop = asyncio.get_running_loop()
    fetch_res = await loop.run_in_executor(None, fetch_schedule, student_id)
    
    if not fetch_res.success:
        logger.warning(f"Не удалось обновить {target_id}: {fetch_res.error} (сайт ДГТУ может быть недоступен)")
        return

    old_record = db.get_schedule(target_id)
    new_hash = Database.calculate_hash(extract_lessons(fetch_res.data))

    if old_record is not None and old_record["hash"] != new_hash:
        logger.info(f"⚡ Обнаружено изменение расписания для {target_id}!")
        changes = compare_schedules(
            old_data=old_record["data"], 
            new_data=fetch_res.data, 
            only_upcoming=True
        )

        if changes:
            logger.info(f"Зафиксировано {len(changes)} изменений для {target_id}")
            changes_dicts = [c.to_dict() for c in changes]
            db.log_changes(target_id, changes_dicts)

            # Отправляем уведомления подписчикам в Telegram
            try:
                await broadcast_schedule_changes(target_id, changes_dicts)
            except Exception as tg_err:
                logger.error(f"Ошибка при отправке Telegram-уведомлений: {tg_err}")

            push = format_push_notification(changes)
            if push:
                logger.info(f"🔔 [PUSH] {push['title']}: {push['body']}")
                # Здесь вызывается FCM пуш-сервис (когда будет настроен ключ Firebase)

    # Сохраняем свежую версию
    db.save_schedule(
        target_id=target_id,
        target_type="student",
        data=fetch_res.data,
        date_uploading=fetch_res.upload_date
    )
    logger.info(f"Синхронизация {target_id} успешно завершена")


async def periodic_check_job():
    """Периодическая задача: опрашивает всех отслеживаемых студентов."""
    logger.info("--- Старт периодической проверки расписаний ---")
    targets = db.get_active_targets()
    
    if not targets:
        logger.info("Нет активных студентов в БД для проверки.")
        return

    for t in targets:
        target_id = t["target_id"]
        # Извлекаем ID студента (student_347338 -> 347338)
        if target_id.startswith("student_"):
            s_id = target_id.replace("student_", "")
            try:
                await sync_target(target_id, s_id)
            except Exception as e:
                logger.error(f"Ошибка при синхронизации {target_id}: {e}")
            
            # Вежливая пауза 1 сек между запросами к ДГТУ
            await asyncio.sleep(1.0)

    logger.info("--- Периодическая проверка завершена ---")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # При старте приложения
    logger.info("Запуск сервера расписания ДГТУ...")
    set_database(db)

    # Фоновый запуск Telegram-бота (@dstu_schedule_notify_bot)
    bot_task = asyncio.create_task(start_bot_polling())
    logger.info("Telegram-бот успешно инициализирован в фоне")

    # Опрос каждые 45 минут (в дневное время)
    scheduler.add_job(periodic_check_job, "interval", minutes=45, id="schedule_checker")
    scheduler.start()
    logger.info("Планировщик фоновых проверок успешно запущен (интервал 45 мин)")
    yield
    # При остановке приложения
    bot_task.cancel()
    scheduler.shutdown()
    logger.info("Планировщик и Telegram-бот остановлены.")


app = FastAPI(
    title="DSTU Schedule API",
    description="Бэкенд сервис мониторинга и кэширования расписания ДГТУ",
    version="1.0.0",
    lifespan=lifespan
)

# Разрешаем CORS для мобильного приложения и веб-клиентов
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/api/health")
async def health_check():
    """Проверка состояния сервера."""
    return {"status": "ok", "service": "dstu-schedule-backend"}


@app.get("/api/schedule/{student_id}")
async def get_schedule(
    student_id: int, 
    force_refresh: bool = Query(False, description="Принудительно запросить свежие данные из ДГТУ")
):
    """
    Получить расписание студента.
    Сначала проверяет локальную базу данных (кэш).
    Если данных нет или запрошен force_refresh — делает запрос в ДГТУ.
    """
    target_id = f"student_{student_id}"
    cached = db.get_schedule(target_id)

    if cached and not force_refresh:
        # Также достаем последние изменения, чтобы мобилка могла пометить отмененные пары
        recent_changes = db.get_recent_changes(target_id, limit=50)
        return {
            "source": "cache",
            "target_id": target_id,
            "updated_at": cached["updated_at"],
            "date_uploading": cached["date_uploading"],
            "data": cached["data"],
            "recent_changes": recent_changes,
            "warning": None
        }

    # Запрашиваем сайт ДГТУ
    loop = asyncio.get_running_loop()
    fetch_res = await loop.run_in_executor(None, fetch_schedule, student_id)

    if not fetch_res.success:
        if cached:
            # Сервер вуза упал, но у нас есть копия! Спасаем пользователя
            recent_changes = db.get_recent_changes(target_id, limit=50)
            return {
                "source": "cache_fallback",
                "target_id": target_id,
                "updated_at": cached["updated_at"],
                "date_uploading": cached["date_uploading"],
                "data": cached["data"],
                "recent_changes": recent_changes,
                "warning": f"Сайт ДГТУ сейчас недоступен ({fetch_res.error}). Показана сохраненная версия."
            }
        raise HTTPException(
            status_code=502, 
            detail=f"Не удалось получить расписание с сайта ДГТУ: {fetch_res.error}"
        )

    # Если скачалось успешно — проверяем изменения и сохраняем
    if cached:
        new_hash = Database.calculate_hash(extract_lessons(fetch_res.data))
        if cached["hash"] != new_hash:
            changes = compare_schedules(cached["data"], fetch_res.data, only_upcoming=True)
            if changes:
                db.log_changes(target_id, [c.to_dict() for c in changes])

    db.save_schedule(
        target_id=target_id,
        target_type="student",
        data=fetch_res.data,
        date_uploading=fetch_res.upload_date
    )

    recent_changes = db.get_recent_changes(target_id, limit=50)
    return {
        "source": "live",
        "target_id": target_id,
        "date_uploading": fetch_res.upload_date,
        "data": fetch_res.data,
        "recent_changes": recent_changes,
        "warning": None
    }


@app.get("/api/changes/{student_id}")
async def get_changes(student_id: int, limit: int = Query(30, ge=1, le=100)):
    """История изменений (отмены, переносы) для студента."""
    target_id = f"student_{student_id}"
    changes = db.get_recent_changes(target_id, limit=limit)
    return {
        "student_id": student_id,
        "count": len(changes),
        "changes": changes
    }


@app.post("/api/subscribe")
async def subscribe(sub: SubscriptionRequest):
    """Регистрация FCM-токена устройства студента для получения пушей."""
    target_id = f"student_{sub.student_id}"
    # Сохраняем в таблицу subscriptions
    from datetime import datetime
    now = datetime.now().isoformat()
    with db._get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO subscriptions (device_token, target_id, created_at, last_active_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(device_token, target_id) DO UPDATE SET last_active_at = excluded.last_active_at
        """, (sub.device_token, target_id, now, now))
        conn.commit()

    # Если расписания этого студента еще нет в базе — сразу запускаем загрузку в фоне
    if not db.get_schedule(target_id):
        asyncio.create_task(sync_target(target_id, sub.student_id))

    return {"status": "ok", "message": f"Успешно подписан на обновления {target_id}"}


@app.post("/api/sync-now")
async def manual_sync_trigger():
    """Принудительный запуск фоновой проверки всех студентов прямо сейчас."""
    asyncio.create_task(periodic_check_job())
    return {"status": "ok", "message": "Фоновая синхронизация запущена"}


@app.post("/api/simulate/{student_id}")
async def simulate_changes(student_id: int):
    """
    Симулирует изменения в расписании студента:
    1. Перенос аудитории для 5-й пары (2-805 -> 8-402).
    2. Отмену 6-й пары (Экономика игр).
    """
    target_id = f"student_{student_id}"
    cached = db.get_schedule(target_id)
    if not cached:
        # Сначала загружаем
        fetch_res = fetch_schedule(student_id)
        if not fetch_res.success:
            raise HTTPException(status_code=502, detail="Не удалось загрузить расписание ДГТУ для симуляции")
        db.save_schedule(target_id, "student", fetch_res.data, fetch_res.upload_date)
        cached = db.get_schedule(target_id)

    data = cached["data"]
    rasp = data.get("data", {}).get("rasp", [])

    simulated_changes = []
    from datetime import datetime
    today_str = datetime.now().strftime("%Y-%m-%d")

    # Ищем пары на сегодня (или берем ближайшие доступные)
    today_lessons = [l for l in rasp if l.get("дата", "").startswith(today_str)]
    if not today_lessons and rasp:
        first_date = rasp[0].get("дата", "")[:10]
        today_lessons = [l for l in rasp if l.get("дата", "").startswith(first_date)]

    new_rasp = []
    for l in rasp:
        code = l.get("код")
        num = l.get("номерЗанятия")
        date = l.get("дата", "")[:10]

        # Симулируем перенос 5-й пары (или первой попавшейся сегодня)
        if today_lessons and l == today_lessons[0]:
            old_aud = l.get("аудитория", "")
            l["аудитория"] = "8-402"
            simulated_changes.append({
                "type": "ROOM_CHANGED",
                "lesson_id": code,
                "date": date,
                "lesson_num": num,
                "subject": l.get("дисциплина", ""),
                "details": f"Аудитория перенесена: {old_aud} ➔ 8-402",
                "human_message": f"{date}, {num}-я пара: аудитория перенесена в 8-402 (была {old_aud})",
                "old_lesson": l,
                "new_lesson": l
            })
            new_rasp.append(l)

        # Симулируем отмену 6-й пары (или второй попавшейся сегодня)
        elif len(today_lessons) > 1 and l == today_lessons[1]:
            old_aud = l.get("аудитория", "")
            simulated_changes.append({
                "type": "CANCELLED",
                "lesson_id": code,
                "date": date,
                "lesson_num": num,
                "subject": l.get("дисциплина", ""),
                "details": f"Пара отменена преподавателем (была в ауд. {old_aud})",
                "human_message": f"{date}, {num}-я пара ({l.get('дисциплина', '')}): пара отменена!",
                "old_lesson": l,
                "new_lesson": None
            })
            # Не добавляем в new_rasp (симулируем удаление парой из базы вуза)
        else:
            new_rasp.append(l)

    # Сохраняем обновленные данные и историю изменений
    data["data"]["rasp"] = new_rasp
    db.save_schedule(target_id, "student", data, cached.get("date_uploading"))
    db.log_changes(target_id, simulated_changes)

    # Рассылаем симулированные изменения в Telegram
    try:
        await broadcast_schedule_changes(target_id, simulated_changes)
    except Exception as tg_err:
        logger.error(f"Ошибка при отправке симулированных изменений в Telegram: {tg_err}")

    return {
        "status": "ok",
        "message": f"Успешно симулировано {len(simulated_changes)} изменений",
        "changes": simulated_changes
    }


@app.post("/api/simulate/reset/{student_id}")
async def reset_simulation(student_id: int):
    """Сбрасывает симуляцию: очищает историю изменений и повторно стягивает расписание из ДГТУ."""
    target_id = f"student_{student_id}"
    db.clear_changes(target_id)
    fetch_res = fetch_schedule(student_id)
    if fetch_res.success:
        db.save_schedule(target_id, "student", fetch_res.data, fetch_res.upload_date)
    return {"status": "ok", "message": "Симуляция сброшена, расписание восстановлено из ДГТУ"}


@app.get("/app", response_class=HTMLResponse)
async def open_in_mobile_app(
    student_id: Optional[str] = Query(None),
    date: Optional[str] = Query(None)
):
    """
    Редирект-страница для кнопки 'Открыть в приложении' из Telegram.
    Пытается открыть приложение по схеме dstu-schedule://open
    """
    deep_link = f"dstu-schedule://open?student_id={student_id or ''}&date={date or ''}"
    html_content = f"""<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ДГТУ Расписание</title>
    <meta http-equiv="refresh" content="0; url={deep_link}">
    <style>
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            background-color: #0f172a;
            color: #f8fafc;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            margin: 0;
            padding: 24px;
            box-sizing: border-box;
            text-align: center;
        }}
        .card {{
            background: #1e293b;
            padding: 36px 24px;
            border-radius: 24px;
            box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.5);
            max-width: 420px;
            width: 100%;
            border: 1px solid rgba(255, 255, 255, 0.08);
        }}
        .btn {{
            display: inline-block;
            background-color: #2563eb;
            color: white;
            text-decoration: none;
            padding: 14px 28px;
            border-radius: 12px;
            font-weight: 600;
            font-size: 16px;
            margin-top: 24px;
            box-shadow: 0 4px 14px rgba(37, 99, 235, 0.4);
        }}
    </style>
</head>
<body>
    <div class="card">
        <div style="font-size: 48px; margin-bottom: 12px;">🎓</div>
        <h2 style="margin: 0 0 12px 0;">ДГТУ Расписание</h2>
        <p style="color: #94a3b8; font-size: 15px; margin: 0 0 16px 0;">
            Открываем расписание в установленном приложении...
        </p>
        <a href="{deep_link}" class="btn">📲 Открыть приложение</a>
        <p style="font-size: 12px; color: #64748b; margin-top: 28px;">
            Если приложение не открылось автоматически, нажмите кнопку выше.
        </p>
    </div>
</body>
</html>"""
    return HTMLResponse(content=html_content)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("server:app", host="0.0.0.0", port=8000, reload=True)
