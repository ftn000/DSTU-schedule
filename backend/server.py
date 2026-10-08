"""
REST API сервер на FastAPI с интегрированным фоновым планировщиком (APScheduler).

Функционал:
1. Выдача расписания для мобильного приложения (с защитой от сбоев ДГТУ и кэшем).
2. Выдача истории изменений (отмен, переносов) для студента.
3. Регистрация устройств для push-уведомлений.
4. Фоновый опрос API ДГТУ по расписанию (раз в 30-60 минут) с выявлением диффов.
"""

import os
import sys
import logging
import asyncio
import hashlib
import json
import uuid
import shutil
import urllib.request
from typing import Optional, List, Dict, Any
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query, Request, Header
from fastapi.responses import HTMLResponse, FileResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from apscheduler.schedulers.asyncio import AsyncIOScheduler

from database import Database
from fetcher import fetch_schedule
from diff_engine import compare_schedules, format_push_notification, extract_lessons
from telegram_bot import (
    start_bot_polling, 
    set_database, 
    broadcast_schedule_changes, 
    broadcast_app_update,
    broadcast_task_deadlines,
    broadcast_new_tasks,
    _get_student_group_name,
)


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

    # Синхронизируем практические занятия в модуль заданий
    try:
        group_name = _get_student_group_name(student_id, fetch_res.data)
        lessons = extract_lessons(fetch_res.data)
        new_tasks = db.sync_tasks_from_schedule(group_name, lessons)
        if new_tasks > 0:
            logger.info(f"Синхронизировано {new_tasks} новых заданий для {group_name}")
            await broadcast_new_tasks(group_name, new_tasks)
    except Exception as sync_e:
        logger.warning(f"Ошибка синхронизации заданий для {target_id}: {sync_e}")

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
    
    # Проверка появления нового билда APK
    try:
        await check_and_notify_apk_update()
    except Exception as e:
        logger.error(f"Ошибка при периодической проверке обновления APK: {e}")

    # Проверка горящих дедлайнов по практикам (раз в день)
    try:
        await broadcast_task_deadlines(force=False)
    except Exception as e:
        logger.error(f"Ошибка при периодической проверке дедлайнов: {e}")


def get_apk_file_hash(apk_path: str) -> Optional[str]:
    """Вычисляет SHA-256 хеш APK файла для точного отслеживания релизов."""
    if not os.path.exists(apk_path):
        return None
    hasher = hashlib.sha256()
    with open(apk_path, "rb") as f:
        while chunk := f.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest()


def get_app_version_meta() -> Dict[str, Any]:
    """Считывает метаданные актуальной версии из version.json."""
    meta_path = os.path.join(os.path.dirname(__file__), "version.json")
    if os.path.exists(meta_path):
        try:
            with open(meta_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {"version": "1.4.9", "build_number": 15}


async def check_and_notify_apk_update(force: bool = False) -> int:
    """
    Проверяет, появился ли на сервере новый файл APK (по SHA-256 хешу).
    Если хеш изменился (или force=True), рассылает уведомление всем пользователям в Telegram.
    """
    apk_path = os.path.join(os.path.dirname(__file__), "DSTU-schedule.apk")
    if not os.path.exists(apk_path):
        apk_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "DSTU-schedule.apk")
    if not os.path.exists(apk_path):
        logger.warning(f"APK файл не найден по пути: {apk_path}")
        return 0

    current_hash = get_apk_file_hash(apk_path)
    if not current_hash:
        return 0

    last_notified_hash = db.get_setting("last_notified_apk_hash")
    meta = get_app_version_meta()
    version = meta.get("version", "1.4.9")
    build_num = meta.get("build_number", 15)
    changelog = meta.get("changelog")

    if force or (current_hash != last_notified_hash):
        logger.info(
            f"🚀 Обнаружен новый билд APK {version}+{build_num}! "
            f"(хеш: {current_hash[:10]}..., прошлый: {str(last_notified_hash)[:10]}...). "
            f"Запуск рассылки уведомлений в Telegram..."
        )
        delivered = await broadcast_app_update(
            version=version,
            build_number=build_num,
            changelog=changelog
        )
        db.set_setting("last_notified_apk_hash", current_hash)
        db.set_setting("last_notified_apk_version", f"{version}+{build_num}")
        logger.info(f"Рассылка релиза {version}+{build_num} завершена: доставлено {delivered} подписчикам.")
        return delivered

    return 0


@asynccontextmanager
async def lifespan(app: FastAPI):
    # При старте приложения
    logger.info("Запуск сервера расписания ДГТУ...")
    set_database(db)

    # Фоновый запуск Telegram-бота (@dstu_schedule_notify_bot)
    bot_task = asyncio.create_task(start_bot_polling())
    logger.info("Telegram-бот успешно инициализирован в фоне")

    # Проверка и рассылка информации о новом APK через 4 секунды после старта бота
    async def delayed_apk_check():
        await asyncio.sleep(4.0)
        try:
            await check_and_notify_apk_update()
        except Exception as e:
            logger.error(f"Ошибка при стартовой проверке релиза APK: {e}")

    asyncio.create_task(delayed_apk_check())

    # Опрос каждые 45 минут (в дневное время)
    scheduler.add_job(periodic_check_job, "interval", minutes=45, id="schedule_checker")
    # Напоминание о дедлайнах каждое утро в 09:00
    scheduler.add_job(broadcast_task_deadlines, "cron", hour=9, minute=0, id="task_deadlines_morning")
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
    version="1.3.1",
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
                changes_dicts = [c.to_dict() for c in changes]
                db.log_changes(target_id, changes_dicts)
                # Отправляем уведомления подписчикам в Telegram
                try:
                    asyncio.create_task(broadcast_schedule_changes(target_id, changes_dicts))
                except Exception as tg_err:
                    logger.error(f"Ошибка при отправке Telegram-уведомлений: {tg_err}")

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


@app.post("/api/broadcast-apk-update")
async def trigger_apk_update_broadcast(force: bool = Query(False, description="Принудительно отправить даже если хеш не изменился")):
    """Ручной запуск проверки и рассылки уведомления о новой версии приложения в Telegram."""
    delivered = await check_and_notify_apk_update(force=force)
    return {
        "status": "ok",
        "delivered_to_users": delivered,
        "message": f"Оповещение разослано {delivered} подписчикам" if delivered > 0 else "Новый билд не обнаружен (или уже был разослан). Используйте force=true для принудительной отправки."
    }


CI_DEPLOY_TOKEN = os.getenv("CI_DEPLOY_TOKEN", "dstu_schedule_ci_deploy_token_2026")


@app.get("/api/ci/keystore")
async def get_ci_keystore(x_ci_token: Optional[str] = Header(None, alias="X-CI-Token")):
    """Отдает релизный keystore для сборки APK в CI/CD."""
    if x_ci_token != CI_DEPLOY_TOKEN:
        raise HTTPException(status_code=403, detail="Доступ запрещен: неверный CI токен")

    keystore_path = "/opt/dstu-schedule/dstu_release.jks"
    if not os.path.exists(keystore_path):
        keystore_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "dstu_release.jks")
    if not os.path.exists(keystore_path):
        raise HTTPException(status_code=404, detail="Keystore не найден на сервере")
    return FileResponse(keystore_path, filename="dstu_release.jks", media_type="application/octet-stream")


@app.post("/api/ci/deploy-apk")
async def deploy_apk_from_ci(
    request: Request,
    x_ci_token: Optional[str] = Header(None, alias="X-CI-Token")
):
    """Принимает бинарный поток свежесобранного APK из CI и обновляет его на сервере."""
    if x_ci_token != CI_DEPLOY_TOKEN:
        raise HTTPException(status_code=403, detail="Доступ запрещен: неверный CI токен")

    target_apk = os.path.join(os.path.dirname(__file__), "DSTU-schedule.apk")
    temp_apk = f"{target_apk}.tmp"
    total_bytes = 0

    try:
        with open(temp_apk, "wb") as f:
            async for chunk in request.stream():
                total_bytes += len(chunk)
                f.write(chunk)
        if total_bytes < 1000000:
            if os.path.exists(temp_apk):
                os.remove(temp_apk)
            raise HTTPException(status_code=400, detail="Размер файла слишком мал для валидного APK")

        shutil.move(temp_apk, target_apk)
        logger.info(f"🎉 Новый APK успешно загружен через CI ({total_bytes} байт)")
    except HTTPException:
        raise
    except Exception as e:
        if os.path.exists(temp_apk):
            os.remove(temp_apk)
        logger.error(f"Ошибка при сохранении APK из CI: {e}")
        raise HTTPException(status_code=500, detail=f"Ошибка сохранения APK: {e}")

    # Запускаем проверку хеша и рассылку обновления пользователям
    delivered = await check_and_notify_apk_update()
    meta = get_app_version_meta()
    return {
        "status": "ok",
        "size": total_bytes,
        "version": meta.get("version"),
        "build_number": meta.get("build_number"),
        "telegram_subscribers_notified": delivered
    }


@app.post("/api/ci/sync-latest-apk")
async def sync_latest_apk_from_github(
    x_ci_token: Optional[str] = Header(None, alias="X-CI-Token")
):
    """Скачивает самый свежий релизный APK из GitHub Releases на сервер."""
    if x_ci_token != CI_DEPLOY_TOKEN:
        raise HTTPException(status_code=403, detail="Доступ запрещен: неверный CI токен")

    meta = get_app_version_meta()
    version = meta.get("version", "1.8.3")
    url = f"https://github.com/ftn000/DSTU-schedule/releases/download/v{version}/DSTU-schedule.apk"

    target_apk = os.path.join(os.path.dirname(__file__), "DSTU-schedule.apk")
    temp_apk = f"{target_apk}.tmp"

    try:
        req = urllib.request.Request(
            url, 
            headers={"User-Agent": "DSTU-Schedule-Server/1.0"}
        )
        with urllib.request.urlopen(req, timeout=60) as resp, open(temp_apk, "wb") as out_f:
            shutil.copyfileobj(resp, out_f)

        if os.path.getsize(temp_apk) < 1000000:
            os.remove(temp_apk)
            raise HTTPException(status_code=400, detail="Загруженный файл поврежден или мал")

        shutil.move(temp_apk, target_apk)
        logger.info(f"🎉 Новый APK v{version} успешно скачан с GitHub Releases")
    except Exception as e:
        if os.path.exists(temp_apk):
            os.remove(temp_apk)
        logger.error(f"Ошибка при скачивании APK с GitHub Releases: {e}")
        raise HTTPException(status_code=500, detail=f"Ошибка скачивания APK: {e}")

    delivered = await check_and_notify_apk_update()
    return {
        "status": "ok",
        "version": version,
        "telegram_subscribers_notified": delivered
    }


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


@app.api_route("/download/DSTU-schedule.apk", methods=["GET", "HEAD"])
async def download_apk():
    """Прямое скачивание актуального APK-файла мобильного приложения."""
    apk_path = os.path.join(os.path.dirname(__file__), "DSTU-schedule.apk")
    if not os.path.exists(apk_path):
        apk_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "DSTU-schedule.apk")
    if not os.path.exists(apk_path):
        raise HTTPException(status_code=404, detail="APK-файл временно недоступен на сервере")
    return FileResponse(
        path=apk_path,
        filename="DSTU-schedule.apk",
        media_type="application/vnd.android.package-archive",
    )


@app.api_route("/download/DSTU-schedule-windows.zip", methods=["GET", "HEAD"])
@app.api_route("/download/windows", methods=["GET", "HEAD"])
async def download_windows_zip():
    """Прямое скачивание портативной сборки приложения для Windows (.ZIP)."""
    zip_path = os.path.join(os.path.dirname(__file__), "DSTU-schedule-windows.zip")
    if not os.path.exists(zip_path):
        zip_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "DSTU-schedule-windows.zip")
    if not os.path.exists(zip_path):
        raise HTTPException(status_code=404, detail="Сборка для Windows временно недоступна на сервере")
    return FileResponse(
        path=zip_path,
        filename="DSTU-schedule-windows-x64.zip",
        media_type="application/zip",
    )


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
            display: block;
            background-color: #2563eb;
            color: white;
            text-decoration: none;
            padding: 14px 28px;
            border-radius: 12px;
            font-weight: 600;
            font-size: 16px;
            margin-top: 20px;
            box-shadow: 0 4px 14px rgba(37, 99, 235, 0.4);
        }}
        .btn-secondary {{
            display: block;
            background-color: rgba(255, 255, 255, 0.08);
            color: #e2e8f0;
            text-decoration: none;
            padding: 12px 24px;
            border-radius: 12px;
            font-weight: 500;
            font-size: 14px;
            margin-top: 12px;
            border: 1px solid rgba(255, 255, 255, 0.14);
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
        <a href="/download/DSTU-schedule.apk" class="btn-secondary">📱 Скачать для Android (.APK)</a>
        <a href="/download/DSTU-schedule-windows.zip" class="btn-secondary">💻 Скачать для Windows (.ZIP)</a>
        <p style="font-size: 12px; color: #64748b; margin-top: 24px;">
            Если приложение не открылось автоматически, скачайте сборку для вашего устройства.
        </p>
    </div>
</body>
</html>"""
    return HTMLResponse(content=html_content)


# -------------------------------------------------------------
# API: Модуль заданий, практик и файлов («Тудушка / Практики»)
# -------------------------------------------------------------

UPLOADS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "uploads")
os.makedirs(UPLOADS_DIR, exist_ok=True)
MAX_FILE_SIZE = 50 * 1024 * 1024  # 50 MB - строгий лимит размера файла


class TaskCreateRequest(BaseModel):
    group_name: str
    subject: str
    title: str
    lesson_type: Optional[str] = "Практика"
    lesson_num: Optional[int] = None
    lesson_date: Optional[str] = None
    description: Optional[str] = None
    deadline: Optional[str] = None
    created_by: Optional[str] = None
    task_id: Optional[int] = None
    semester: Optional[str] = None


class TaskSubmissionRequest(BaseModel):
    student_id: str
    status: str = "todo"  # todo, in_progress, submitted, accepted
    text_solution: Optional[str] = None
    grade: Optional[str] = None


class TaskSyncScheduleRequest(BaseModel):
    group_name: str
    lessons: List[Dict[str, Any]]


@app.get("/api/tasks")
async def get_tasks(
    group_name: str = Query(..., description="Название группы, например ВПР42"),
    student_id: Optional[str] = Query(None, description="ID студента для получения его персонального решения"),
    semester: Optional[str] = Query(None, description="Фильтр по семестру, например 'Осень 2026' или 'Все'")
):
    """Возвращает список заданий группы с файлами заданий и индивидуальными решениями студента."""
    tasks = db.get_tasks(group_name, student_id, semester=semester)
    return {"tasks": tasks, "count": len(tasks)}


@app.get("/api/tasks/{task_id}")
async def get_task(
    task_id: int,
    student_id: Optional[str] = Query(None, description="ID студента")
):
    """Возвращает детальную информацию по одному заданию."""
    task = db.get_task(task_id, student_id)
    if not task:
        raise HTTPException(status_code=404, detail="Задание не найдено")
    return task


@app.post("/api/tasks")
async def create_or_update_task(req: TaskCreateRequest):
    """Создает или редактирует задание для группы."""
    task_id = db.create_or_update_task(
        group_name=req.group_name,
        subject=req.subject,
        title=req.title,
        lesson_type=req.lesson_type or "Практика",
        lesson_num=req.lesson_num,
        lesson_date=req.lesson_date,
        description=req.description,
        deadline=req.deadline,
        created_by=req.created_by,
        task_id=req.task_id,
        semester=req.semester
    )
    return {"success": True, "task_id": task_id}


@app.delete("/api/tasks/{task_id}")
async def delete_task(task_id: int):
    """Удаляет задание и все связанные файлы с сервера."""
    files_to_delete = db.delete_task(task_id)
    for filename in files_to_delete:
        file_path = os.path.join(UPLOADS_DIR, filename)
        if os.path.exists(file_path):
            try:
                os.remove(file_path)
            except Exception as e:
                logger.warning(f"Ошибка удаления файла {file_path}: {e}")
    return {"success": True, "task_id": task_id}


@app.post("/api/tasks/{task_id}/submission")
async def save_submission(task_id: int, req: TaskSubmissionRequest):
    """Сохраняет статус или текстовое решение студента."""
    sub_id = db.save_submission(
        task_id=task_id,
        student_id=req.student_id,
        status=req.status,
        text_solution=req.text_solution,
        grade=req.grade
    )
    return {"success": True, "submission_id": sub_id}


@app.post("/api/tasks/{task_id}/upload")
async def upload_task_file_stream(
    task_id: int,
    request: Request,
    filename: str = Query(..., description="Исходное имя файла"),
    file_type: str = Query("task_attachment", description="task_attachment или submission_attachment"),
    student_id: Optional[str] = Query(None, description="ID студента при отправке решения")
):
    """
    Загрузка файла потоком байт (без сторонних библиотек multipart).
    Жесткий лимит 50 МБ.
    """
    content_length = request.headers.get("content-length")
    if content_length and int(content_length) > MAX_FILE_SIZE:
        raise HTTPException(
            status_code=413,
            detail=f"Файл слишком большой. Максимальный лимит: 50 МБ."
        )

    task = db.get_task(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Задание не найдено")

    unique_name = f"{uuid.uuid4().hex[:12]}_{os.path.basename(filename)}"
    target_path = os.path.join(UPLOADS_DIR, unique_name)

    total_bytes = 0
    try:
        with open(target_path, "wb") as f:
            async for chunk in request.stream():
                total_bytes += len(chunk)
                if total_bytes > MAX_FILE_SIZE:
                    f.close()
                    if os.path.exists(target_path):
                        os.remove(target_path)
                    raise HTTPException(
                        status_code=413,
                        detail="Размер файла превышает лимит 50 МБ"
                    )
                f.write(chunk)
    except HTTPException:
        raise
    except Exception as e:
        if os.path.exists(target_path):
            os.remove(target_path)
        raise HTTPException(status_code=500, detail=f"Ошибка сохранения файла: {e}")

    submission_id = None
    if file_type == "submission_attachment":
        if not student_id:
            if os.path.exists(target_path):
                os.remove(target_path)
            raise HTTPException(status_code=400, detail="Для прикрепления файла к решению требуется student_id")
        submission_id = db.save_submission(task_id=task_id, student_id=student_id, status="in_progress")

    mime_type = request.headers.get("content-type") or "application/octet-stream"
    file_id = db.add_task_file(
        task_id=task_id,
        submission_id=submission_id,
        file_type=file_type,
        filename=filename,
        stored_filename=unique_name,
        file_size=total_bytes,
        mime_type=mime_type,
        uploaded_by=student_id
    )

    return {
        "success": True,
        "file": {
            "id": file_id,
            "task_id": task_id,
            "submission_id": submission_id,
            "file_type": file_type,
            "filename": filename,
            "file_size": total_bytes,
            "mime_type": mime_type
        }
    }


@app.get("/api/tasks/files/{file_id}/download")
async def download_task_file(file_id: int):
    """Скачивание файла задания или решения."""
    record = db.get_task_file(file_id)
    if not record:
        raise HTTPException(status_code=404, detail="Файл не найден")

    file_path = os.path.join(UPLOADS_DIR, record["stored_filename"])
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="Физический файл отсутствует на сервере")

    return FileResponse(
        path=file_path,
        filename=record["filename"],
        media_type=record.get("mime_type") or "application/octet-stream"
    )


@app.delete("/api/tasks/files/{file_id}")
async def delete_task_file(file_id: int):
    """Удаление файла из БД и с диска."""
    record = db.delete_task_file(file_id)
    if not record:
        raise HTTPException(status_code=404, detail="Файл не найден")

    file_path = os.path.join(UPLOADS_DIR, record["stored_filename"])
    if os.path.exists(file_path):
        try:
            os.remove(file_path)
        except Exception as e:
            logger.warning(f"Ошибка удаления файла с диска: {e}")

    return {"success": True, "file_id": file_id}


@app.post("/api/tasks/sync-schedule")
async def sync_tasks_from_schedule(req: TaskSyncScheduleRequest):
    """Синхронизирует и создает задания из расписания группы (практики/лабораторные)."""
    created = db.sync_tasks_from_schedule(req.group_name, req.lessons)
    return {"success": True, "created_count": created}



if __name__ == "__main__":
    import uvicorn
    uvicorn.run("server:app", host="0.0.0.0", port=8000, reload=True)

