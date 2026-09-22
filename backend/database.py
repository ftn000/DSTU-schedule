"""
Модуль работы с локальной базой данных SQLite для хранения расписания и истории изменений.
Использует стандартную библиотеку sqlite3 (без внешних зависимостей).
"""

import sqlite3
import json
import hashlib
from datetime import datetime
from typing import Optional, List, Dict, Any


class Database:
    def __init__(self, db_path: str = "schedule.db"):
        self.db_path = db_path
        self._init_tables()

    def _get_connection(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_tables(self):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            
            # Таблица снапшотов расписания
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS schedules (
                    target_id TEXT PRIMARY KEY,
                    target_type TEXT NOT NULL,
                    raw_json TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    date_uploading TEXT,
                    updated_at TIMESTAMP NOT NULL
                )
            """)

            # Таблица истории зафиксированных изменений (отмены, переносы)
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS changes_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    target_id TEXT NOT NULL,
                    change_type TEXT NOT NULL,
                    lesson_id INTEGER,
                    lesson_date TEXT NOT NULL,
                    lesson_num INTEGER,
                    subject TEXT,
                    details TEXT NOT NULL,
                    human_message TEXT NOT NULL,
                    lesson_data TEXT,
                    detected_at TIMESTAMP NOT NULL,
                    FOREIGN KEY (target_id) REFERENCES schedules(target_id)
                )
            """)

            # Автоматическая миграция колонок для уже созданной таблицы
            try:
                cursor.execute("ALTER TABLE changes_history ADD COLUMN lesson_id INTEGER")
            except Exception:
                pass
            try:
                cursor.execute("ALTER TABLE changes_history ADD COLUMN lesson_data TEXT")
            except Exception:
                pass

            # Таблица подписок (для push-уведомлений)
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS subscriptions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_token TEXT NOT NULL,
                    target_id TEXT NOT NULL,
                    created_at TIMESTAMP NOT NULL,
                    last_active_at TIMESTAMP NOT NULL,
                    UNIQUE(device_token, target_id)
                )
            """)
            
            conn.commit()

    @staticmethod
    def calculate_hash(data: Any) -> str:
        """Вычисляет SHA-256 хеш данных для мгновенного сравнения."""
        if isinstance(data, (dict, list)):
            dumped = json.dumps(data, sort_keys=True, ensure_ascii=False)
        else:
            dumped = str(data)
        return hashlib.sha256(dumped.encode("utf-8")).hexdigest()

    def get_schedule(self, target_id: str) -> Optional[Dict[str, Any]]:
        """Возвращает текущее сохраненное расписание и хеш."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "SELECT target_id, target_type, raw_json, content_hash, date_uploading, updated_at "
                "FROM schedules WHERE target_id = ?",
                (target_id,)
            )
            row = cursor.fetchone()
            if not row:
                return None
            return {
                "target_id": row["target_id"],
                "target_type": row["target_type"],
                "data": json.loads(row["raw_json"]),
                "hash": row["content_hash"],
                "date_uploading": row["date_uploading"],
                "updated_at": row["updated_at"]
            }

    def save_schedule(
        self, 
        target_id: str, 
        target_type: str, 
        data: Dict[str, Any], 
        date_uploading: Optional[str] = None
    ) -> str:
        """Сохраняет или обновляет расписание в БД. Возвращает вычисленный хеш."""
        raw_json = json.dumps(data, ensure_ascii=False)
        content_hash = self.calculate_hash(data.get("data", {}).get("rasp", data))
        now = datetime.now().isoformat()

        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO schedules (target_id, target_type, raw_json, content_hash, date_uploading, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(target_id) DO UPDATE SET
                    raw_json = excluded.raw_json,
                    content_hash = excluded.content_hash,
                    date_uploading = excluded.date_uploading,
                    updated_at = excluded.updated_at
            """, (target_id, target_type, raw_json, content_hash, date_uploading, now))
            conn.commit()

        return content_hash

    def log_changes(self, target_id: str, changes: List[Dict[str, Any]]):
        """Записывает найденные изменения в журнал истории."""
        if not changes:
            return

        now = datetime.now().isoformat()
        records = [
            (
                target_id,
                ch.get("type", "UNKNOWN"),
                ch.get("lesson_id"),
                ch.get("date", ""),
                ch.get("lesson_num", 0),
                ch.get("subject", ""),
                ch.get("details", ""),
                ch.get("human_message", ""),
                json.dumps(ch.get("old_lesson") or ch.get("new_lesson"), ensure_ascii=False) if (ch.get("old_lesson") or ch.get("new_lesson")) else None,
                now
            )
            for ch in changes
        ]

        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.executemany("""
                INSERT INTO changes_history 
                (target_id, change_type, lesson_id, lesson_date, lesson_num, subject, details, human_message, lesson_data, detected_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, records)
            conn.commit()

    def get_recent_changes(self, target_id: str, limit: int = 50) -> List[Dict[str, Any]]:
        """Возвращает историю изменений для студента/группы."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT id, change_type, lesson_id, lesson_date, lesson_num, subject, details, human_message, lesson_data, detected_at
                FROM changes_history
                WHERE target_id = ?
                ORDER BY id DESC
                LIMIT ?
            """, (target_id, limit))
            results = []
            for row in cursor.fetchall():
                d = dict(row)
                if d.get("lesson_data"):
                    try:
                        d["lesson_data"] = json.loads(d["lesson_data"])
                    except Exception:
                        pass
                results.append(d)
            return results

    def clear_changes(self, target_id: str):
        """Очищает историю изменений для студента (для сброса тестов)."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("DELETE FROM changes_history WHERE target_id = ?", (target_id,))
            conn.commit()

    def get_active_targets(self) -> List[Dict[str, str]]:
        """Возвращает список всех target_id, которые есть в БД или подписках."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT DISTINCT target_id, target_type FROM schedules")
            return [dict(row) for row in cursor.fetchall()]
