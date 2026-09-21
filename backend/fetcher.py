"""
Модуль для безопасного получения расписания с API ДГТУ (edu.donstu.ru).
Поддерживает повторные попытки (retry), кастомные заголовки и строгую валидацию,
чтобы при падении сервера вуза не повреждались локальные данные.
"""

import urllib.request
import urllib.error
import json
import time
from typing import Optional, Dict, Any
from dataclasses import dataclass


BASE_API_URL = "https://edu.donstu.ru/api/Rasp"

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/120.0.0.0 Safari/537.36"
    ),
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7",
}


@dataclass
class FetchResult:
    success: bool
    data: Optional[Dict[str, Any]] = None
    lessons_count: int = 0
    upload_date: Optional[str] = None
    group_name: Optional[str] = None
    error: Optional[str] = None


def fetch_schedule(
    student_id: Optional[int | str] = None,
    group_id: Optional[int | str] = None,
    timeout: int = 15,
    max_retries: int = 2,
    retry_delay: float = 2.0
) -> FetchResult:
    """
    Загружает расписание с сайта ДГТУ.
    
    :param student_id: ID студента (например, 347338)
    :param group_id: ID группы (например, 75049)
    :param timeout: Таймаут запроса в секундах
    :param max_retries: Количество повторных попыток при ошибке соединения
    :param retry_delay: Задержка между попытками
    :return: FetchResult с расписанием или описанием ошибки
    """
    if not student_id and not group_id:
        return FetchResult(success=False, error="Не указан student_id или group_id")

    params = []
    if student_id:
        params.append(f"idStudent={student_id}")
    if group_id:
        params.append(f"idGroup={group_id}")

    url = f"{BASE_API_URL}?{'&'.join(params)}"
    last_error = None

    for attempt in range(1, max_retries + 1):
        try:
            req = urllib.request.Request(url, headers=HEADERS, method="GET")
            with urllib.request.urlopen(req, timeout=timeout) as response:
                status_code = response.status
                if status_code != 200:
                    last_error = f"Сервер вернул статус HTTP {status_code}"
                    time.sleep(retry_delay)
                    continue

                raw_bytes = response.read()
                raw_text = raw_bytes.decode("utf-8", errors="replace")
                parsed_json = json.loads(raw_text)

                # Валидация структуры ответа ДГТУ
                if not isinstance(parsed_json, dict):
                    last_error = "Некорректный формат ответа (ожидался JSON объект)"
                    continue

                data_block = parsed_json.get("data")
                if not data_block or not isinstance(data_block, dict):
                    # Если сервер отдал msg об ошибке
                    msg = parsed_json.get("msg") or "Блок 'data' отсутствует"
                    last_error = f"Ошибка API ДГТУ: {msg}"
                    continue

                rasp_list = data_block.get("rasp")
                if rasp_list is None or not isinstance(rasp_list, list):
                    last_error = "Поле 'rasp' отсутствует или не является списком"
                    continue

                # Извлекаем полезные метаданные
                info_block = data_block.get("info", {})
                upload_date = info_block.get("dateUploadingRasp") if isinstance(info_block, dict) else None
                group_name = (
                    info_block.get("group", {}).get("name") 
                    if isinstance(info_block, dict) and isinstance(info_block.get("group"), dict) 
                    else None
                )

                return FetchResult(
                    success=True,
                    data=parsed_json,
                    lessons_count=len(rasp_list),
                    upload_date=upload_date,
                    group_name=group_name
                )

        except urllib.error.HTTPError as e:
            last_error = f"HTTP ошибка {e.code}: {e.reason}"
        except urllib.error.URLError as e:
            last_error = f"Ошибка сети / сервер недоступен: {e.reason}"
        except json.JSONDecodeError as e:
            last_error = f"Ошибка парсинга JSON: {str(e)}"
        except Exception as e:
            last_error = f"Непредвиденная ошибка: {str(e)}"

        if attempt < max_retries:
            time.sleep(retry_delay)

    return FetchResult(success=False, error=last_error)


if __name__ == "__main__":
    import sys
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass

    test_id = sys.argv[1] if len(sys.argv) > 1 else 347338
    print(f"[INFO] Запрос расписания для student_id={test_id}...")
    res = fetch_schedule(student_id=test_id)
    if res.success:
        print("[SUCCESS] Успешно получено!")
        print(f"  * Занятий в расписании: {res.lessons_count}")
        print(f"  * Группа: {res.group_name}")
        print(f"  * Дата обновления в ДГТУ: {res.upload_date}")
    else:
        print(f"[ERROR] Ошибка получения: {res.error}")

