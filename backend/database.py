"""
Модуль работы с локальной базой данных SQLite для хранения расписания и истории изменений.
Использует стандартную библиотеку sqlite3 (без внешних зависимостей).
"""

import sqlite3
import json
import hashlib
import re
from datetime import datetime, timedelta
from typing import Optional, List, Dict, Any


def clean_subject_name(name: Any) -> str:
    """
    Очищает название предмета от префиксов (лек, пр),
    указателей семестра (например, '(7 семестр)', '( 6 семестр)', '(7 семестр, 26-27)')
    и версий (например, 'V2', 'v2', '(v2)', '(версия 2)').
    """
    if not name:
        return ""
    s = str(name).strip()
    s = re.sub(r'^(?:лек|пр|лаб|сем|зач|экз|конс|кп|кр)[\.\s]+', '', s, flags=re.IGNORECASE)
    s = re.sub(r'\s*\(\s*[^)]*(?:семестр|сем\.?)[^)]*\)', '', s, flags=re.IGNORECASE)
    s = re.sub(r'\s*\(\s*(?:[vVвВ]\s*\d+(?:\.\d+)*|версия\s*\d+)\s*\)', '', s, flags=re.IGNORECASE)
    s = re.sub(r'(?:\s+|^)(?:[vVвВ]\s*\d+(?:\.\d+)*|версия\s*\d+)(?=\s|$|[),.;])', '', s, flags=re.IGNORECASE)
    s = re.sub(r'\s*\(\s*[^)]*(?:семестр|сем\.?)[^)]*\)', '', s, flags=re.IGNORECASE)
    s = re.sub(r'\s+', ' ', s).strip()
    return s or str(name).strip()


class Database:
    def __init__(self, db_path: str = "schedule.db"):
        self.db_path = db_path
        self._init_tables()

    def _get_connection(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.execute("PRAGMA foreign_keys = ON")
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

            # Таблица подписчиков Telegram-бота
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS telegram_subscribers (
                    chat_id INTEGER PRIMARY KEY,
                    student_id TEXT NOT NULL,
                    username TEXT,
                    first_name TEXT,
                    created_at TIMESTAMP NOT NULL,
                    is_active INTEGER DEFAULT 1
                )
            """)

            # Таблица настроек и метаданных приложения (версии, хеши APK)
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS app_settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL,
                    updated_at TIMESTAMP NOT NULL
                )
            """)

            # Таблица заданий и практических занятий (общие для группы)
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS tasks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    group_name TEXT NOT NULL,
                    subject TEXT NOT NULL,
                    title TEXT NOT NULL,
                    lesson_type TEXT DEFAULT 'Практика',
                    lesson_num INTEGER,
                    lesson_date TEXT,
                    description TEXT,
                    deadline TEXT,
                    created_by TEXT,
                    created_at TIMESTAMP NOT NULL,
                    updated_at TIMESTAMP NOT NULL,
                    semester TEXT
                )
            """)
            try:
                cursor.execute("ALTER TABLE tasks ADD COLUMN semester TEXT")
            except Exception:
                pass
            cursor.execute("CREATE INDEX IF NOT EXISTS idx_tasks_group ON tasks(group_name)")
            cursor.execute("CREATE INDEX IF NOT EXISTS idx_tasks_date ON tasks(lesson_date)")
            cursor.execute("CREATE INDEX IF NOT EXISTS idx_tasks_semester ON tasks(semester)")

            # Таблица индивидуальных решений/статусов студентов
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS student_submissions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id INTEGER NOT NULL,
                    student_id TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'todo',
                    text_solution TEXT,
                    grade TEXT,
                    updated_at TIMESTAMP NOT NULL,
                    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE,
                    UNIQUE(task_id, student_id)
                )
            """)
            cursor.execute("CREATE INDEX IF NOT EXISTS idx_submissions_task_student ON student_submissions(task_id, student_id)")

            # Таблица прикрепленных файлов (методички к заданию или файлы решения студента)
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS task_files (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id INTEGER NOT NULL,
                    submission_id INTEGER,
                    file_type TEXT NOT NULL,
                    filename TEXT NOT NULL,
                    stored_filename TEXT NOT NULL,
                    file_size INTEGER NOT NULL,
                    mime_type TEXT,
                    uploaded_by TEXT,
                    created_at TIMESTAMP NOT NULL,
                    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE,
                    FOREIGN KEY (submission_id) REFERENCES student_submissions(id) ON DELETE CASCADE
                )
            """)
            cursor.execute("CREATE INDEX IF NOT EXISTS idx_task_files_task ON task_files(task_id)")
            cursor.execute("CREATE INDEX IF NOT EXISTS idx_task_files_submission ON task_files(submission_id)")
            
            # Автоматическая миграция существующих записей с семестрами и V2
            try:
                cursor.execute("SELECT id, subject, title FROM tasks")
                for r in cursor.fetchall():
                    t_id = r["id"]
                    old_s = r["subject"] or ""
                    old_t = r["title"] or ""
                    new_s = clean_subject_name(old_s)
                    new_t = old_t
                    if old_s and old_s in old_t:
                        new_t = old_t.replace(old_s, new_s)
                    if new_s != old_s or new_t != old_t:
                        cursor.execute("UPDATE tasks SET subject = ?, title = ? WHERE id = ?", (new_s, new_t, t_id))

                cursor.execute("SELECT id, subject FROM changes_history WHERE subject IS NOT NULL")
                for r in cursor.fetchall():
                    c_id = r["id"]
                    old_s = r["subject"] or ""
                    new_s = clean_subject_name(old_s)
                    if new_s != old_s:
                        cursor.execute("UPDATE changes_history SET subject = ? WHERE id = ?", (new_s, c_id))
            except Exception:
                pass

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
        from diff_engine import extract_lessons
        raw_json = json.dumps(data, ensure_ascii=False)
        content_hash = self.calculate_hash(extract_lessons(data))
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

        now = datetime.now().astimezone().isoformat()
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

    def get_recent_changes(self, target_id: str, limit: int = 50, max_days: int = 3) -> List[Dict[str, Any]]:
        """Возвращает историю изменений для студента/группы (по умолчанию за последние 3 дня)."""
        cutoff = (datetime.now() - timedelta(days=max_days)).isoformat()
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT id, change_type, lesson_id, lesson_date, lesson_num, subject, details, human_message, lesson_data, detected_at
                FROM changes_history
                WHERE target_id = ? AND detected_at >= ?
                ORDER BY id DESC
                LIMIT ?
            """, (target_id, cutoff, limit))
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
        """Возвращает список всех target_id, которые есть в БД, подписках или Telegram-подписчиках."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT DISTINCT target_id, target_type FROM schedules
                UNION
                SELECT DISTINCT 'student_' || student_id AS target_id, 'student' AS target_type 
                FROM telegram_subscribers WHERE is_active = 1
            """)
            return [dict(row) for row in cursor.fetchall()]

    def subscribe_telegram(
        self, 
        chat_id: int, 
        student_id: str, 
        username: Optional[str] = None, 
        first_name: Optional[str] = None
    ):
        """Регистрирует или обновляет подписку пользователя Telegram на студента."""
        now = datetime.now().isoformat()
        clean_student_id = str(student_id).replace("student_", "")
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO telegram_subscribers (chat_id, student_id, username, first_name, created_at, is_active)
                VALUES (?, ?, ?, ?, ?, 1)
                ON CONFLICT(chat_id) DO UPDATE SET
                    student_id = excluded.student_id,
                    username = excluded.username,
                    first_name = excluded.first_name,
                    is_active = 1
            """, (chat_id, clean_student_id, username, first_name, now))
            conn.commit()

    def unsubscribe_telegram(self, chat_id: int):
        """Отключает уведомления для чата Telegram."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("UPDATE telegram_subscribers SET is_active = 0 WHERE chat_id = ?", (chat_id,))
            conn.commit()

    def get_telegram_subscriber(self, chat_id: int) -> Optional[Dict[str, Any]]:
        """Возвращает информацию о подписке пользователя Telegram."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "SELECT chat_id, student_id, username, first_name, created_at, is_active "
                "FROM telegram_subscribers WHERE chat_id = ?", 
                (chat_id,)
            )
            row = cursor.fetchone()
            return dict(row) if row else None

    def get_telegram_subscribers(self, target_id: Optional[str] = None) -> List[Dict[str, Any]]:
        """Возвращает список активных подписчиков для target_id (student_347338) или всех."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            if target_id:
                clean_id = str(target_id).replace("student_", "")
                cursor.execute(
                    "SELECT chat_id, student_id, username, first_name "
                    "FROM telegram_subscribers WHERE is_active = 1 AND student_id = ?",
                    (clean_id,)
                )
            else:
                cursor.execute(
                    "SELECT chat_id, student_id, username, first_name "
                    "FROM telegram_subscribers WHERE is_active = 1"
                )
            return [dict(row) for row in cursor.fetchall()]

    def get_setting(self, key: str, default: Optional[str] = None) -> Optional[str]:
        """Возвращает строковое значение настройки/метаданных из таблицы app_settings."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT value FROM app_settings WHERE key = ?", (key,))
            row = cursor.fetchone()
            return row["value"] if row else default

    def set_setting(self, key: str, value: str):
        """Сохраняет или обновляет настройку/метаданные в таблице app_settings."""
        now = datetime.now().isoformat()
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO app_settings (key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value = excluded.value,
                    updated_at = excluded.updated_at
            """, (key, str(value), now))
            conn.commit()

    # ---------------------------------------------------------
    # МОДУЛЬ ЗАДАНИЙ, ПРАКТИК И ФАЙЛОВ (ТУДУШКА)
    # ---------------------------------------------------------

    @staticmethod
    def resolve_semester_name(date_str: Optional[str] = None, fallback_dt: Optional[datetime] = None) -> str:
        """
        Возвращает стандартизированное название семестра:
        'Осень 2026', 'Весна 2026' и т.д.
        Сентябрь-январь: Осень {год начала}
        Февраль-август: Весна {год}
        """
        dt = fallback_dt or datetime.now()
        if date_str:
            try:
                clean = date_str.split("T")[0]
                dt = datetime.strptime(clean, "%Y-%m-%d")
            except Exception:
                pass

        year = dt.year
        month = dt.month
        if month >= 9:
            return f"Осень {year}"
        elif month == 1:
            return f"Осень {year - 1}"
        else:
            return f"Весна {year}"

    def get_tasks(self, group_name: str, student_id: Optional[str] = None, semester: Optional[str] = None) -> List[Dict[str, Any]]:
        """Возвращает список заданий для академической группы с индивидуальными статусами студента."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT id, group_name, subject, title, lesson_type, lesson_num, lesson_date,
                       description, deadline, created_by, created_at, updated_at, semester
                FROM tasks
                WHERE LOWER(TRIM(group_name)) = LOWER(TRIM(?))
                ORDER BY 
                    CASE WHEN lesson_date IS NULL OR lesson_date = '' THEN 1 ELSE 0 END,
                    lesson_date DESC,
                    id DESC
            """, (group_name,))
            rows = cursor.fetchall()
            task_list = [dict(r) for r in rows]

            if not task_list:
                return []

            task_ids = [t["id"] for t in task_list]
            placeholders = ",".join("?" for _ in task_ids)

            # Получаем общие файлы заданий
            cursor.execute(f"""
                SELECT id, task_id, submission_id, file_type, filename, stored_filename, file_size, mime_type, uploaded_by, created_at
                FROM task_files
                WHERE task_id IN ({placeholders}) AND file_type = 'task_attachment'
                ORDER BY id ASC
            """, task_ids)
            task_files_map: Dict[int, List[Dict[str, Any]]] = {}
            for f in cursor.fetchall():
                fd = dict(f)
                task_files_map.setdefault(fd["task_id"], []).append(fd)

            # Получаем решения и файлы решений студента, если student_id передан
            submissions_map: Dict[int, Dict[str, Any]] = {}
            if student_id:
                clean_student_id = str(student_id).replace("student_", "")
                cursor.execute(f"""
                    SELECT id, task_id, student_id, status, text_solution, grade, updated_at
                    FROM student_submissions
                    WHERE task_id IN ({placeholders}) AND student_id = ?
                """, task_ids + [clean_student_id])
                sub_rows = cursor.fetchall()
                sub_ids = []
                for s in sub_rows:
                    sd = dict(s)
                    sd["files"] = []
                    submissions_map[sd["task_id"]] = sd
                    sub_ids.append(sd["id"])

                if sub_ids:
                    sub_placeholders = ",".join("?" for _ in sub_ids)
                    cursor.execute(f"""
                        SELECT id, task_id, submission_id, file_type, filename, stored_filename, file_size, mime_type, uploaded_by, created_at
                        FROM task_files
                        WHERE submission_id IN ({sub_placeholders})
                        ORDER BY id ASC
                    """, sub_ids)
                    for f in cursor.fetchall():
                        fd = dict(f)
                        if fd["task_id"] in submissions_map:
                            submissions_map[fd["task_id"]]["files"].append(fd)

            filtered_list = []
            for t in task_list:
                if not t.get("semester"):
                    t["semester"] = self.resolve_semester_name(t.get("lesson_date") or t.get("deadline") or t.get("created_at"))
                t["task_files"] = task_files_map.get(t["id"], [])
                t["submission"] = submissions_map.get(t["id"], {
                    "id": None,
                    "task_id": t["id"],
                    "student_id": str(student_id or ""),
                    "status": "todo",
                    "text_solution": "",
                    "grade": None,
                    "updated_at": None,
                    "files": []
                })
                if semester and semester != "Все" and t.get("semester") != semester:
                    continue
                filtered_list.append(t)

            return filtered_list

    def get_task(self, task_id: int, student_id: Optional[str] = None) -> Optional[Dict[str, Any]]:
        """Возвращает информацию по конкретному заданию с файлами и решением студента."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT id, group_name, subject, title, lesson_type, lesson_num, lesson_date,
                       description, deadline, created_by, created_at, updated_at, semester
                FROM tasks
                WHERE id = ?
            """, (task_id,))
            row = cursor.fetchone()
            if not row:
                return None
            task = dict(row)
            if not task.get("semester"):
                task["semester"] = self.resolve_semester_name(task.get("lesson_date") or task.get("deadline") or task.get("created_at"))

            # Файлы задания
            cursor.execute("""
                SELECT id, task_id, submission_id, file_type, filename, stored_filename, file_size, mime_type, uploaded_by, created_at
                FROM task_files
                WHERE task_id = ? AND file_type = 'task_attachment'
                ORDER BY id ASC
            """, (task_id,))
            task["task_files"] = [dict(f) for f in cursor.fetchall()]

            # Решение студента
            submission = {
                "id": None,
                "task_id": task_id,
                "student_id": str(student_id or ""),
                "status": "todo",
                "text_solution": "",
                "grade": None,
                "updated_at": None,
                "files": []
            }
            if student_id:
                clean_student_id = str(student_id).replace("student_", "")
                cursor.execute("""
                    SELECT id, task_id, student_id, status, text_solution, grade, updated_at
                    FROM student_submissions
                    WHERE task_id = ? AND student_id = ?
                """, (task_id, clean_student_id))
                srow = cursor.fetchone()
                if srow:
                    submission = dict(srow)
                    cursor.execute("""
                        SELECT id, task_id, submission_id, file_type, filename, stored_filename, file_size, mime_type, uploaded_by, created_at
                        FROM task_files
                        WHERE submission_id = ?
                        ORDER BY id ASC
                    """, (submission["id"],))
                    submission["files"] = [dict(f) for f in cursor.fetchall()]
            task["submission"] = submission
            return task

    def create_or_update_task(
        self,
        group_name: str,
        subject: str,
        title: str,
        lesson_type: str = "Практика",
        lesson_num: Optional[int] = None,
        lesson_date: Optional[str] = None,
        description: Optional[str] = None,
        deadline: Optional[str] = None,
        created_by: Optional[str] = None,
        task_id: Optional[int] = None,
        semester: Optional[str] = None
    ) -> int:
        """Создает или обновляет задание для группы."""
        now = datetime.now().isoformat()
        subject = clean_subject_name(subject)
        if not semester:
            semester = self.resolve_semester_name(lesson_date or deadline or now)
        with self._get_connection() as conn:
            cursor = conn.cursor()
            if task_id:
                cursor.execute("""
                    UPDATE tasks
                    SET group_name = ?, subject = ?, title = ?, lesson_type = ?,
                        lesson_num = ?, lesson_date = ?, description = ?, deadline = ?,
                        updated_at = ?, semester = ?
                    WHERE id = ?
                """, (group_name, subject, title, lesson_type, lesson_num, lesson_date, description, deadline, now, semester, task_id))
                conn.commit()
                return task_id
            else:
                cursor.execute("""
                    INSERT INTO tasks (group_name, subject, title, lesson_type, lesson_num, lesson_date, description, deadline, created_by, created_at, updated_at, semester)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (group_name, subject, title, lesson_type, lesson_num, lesson_date, description, deadline, created_by, now, now, semester))
                conn.commit()
                return cursor.lastrowid

    def delete_task(self, task_id: int) -> List[str]:
        """Удаляет задание и возвращает список имен файлов на диске для физического удаления."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT stored_filename FROM task_files WHERE task_id = ?", (task_id,))
            files_to_delete = [r["stored_filename"] for r in cursor.fetchall()]
            cursor.execute("DELETE FROM tasks WHERE id = ?", (task_id,))
            conn.commit()
            return files_to_delete

    def save_submission(
        self,
        task_id: int,
        student_id: str,
        status: str = "todo",
        text_solution: Optional[str] = None,
        grade: Optional[str] = None
    ) -> int:
        """Создает или обновляет запись о решении студента."""
        now = datetime.now().isoformat()
        clean_student_id = str(student_id).replace("student_", "")
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO student_submissions (task_id, student_id, status, text_solution, grade, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(task_id, student_id) DO UPDATE SET
                    status = excluded.status,
                    text_solution = CASE WHEN excluded.text_solution IS NOT NULL THEN excluded.text_solution ELSE student_submissions.text_solution END,
                    grade = CASE WHEN excluded.grade IS NOT NULL THEN excluded.grade ELSE student_submissions.grade END,
                    updated_at = excluded.updated_at
            """, (task_id, clean_student_id, status, text_solution, grade, now))
            conn.commit()
            cursor.execute("SELECT id FROM student_submissions WHERE task_id = ? AND student_id = ?", (task_id, clean_student_id))
            row = cursor.fetchone()
            return row["id"] if row else 0

    def add_task_file(
        self,
        task_id: int,
        file_type: str,
        filename: str,
        stored_filename: str,
        file_size: int,
        mime_type: Optional[str] = None,
        uploaded_by: Optional[str] = None,
        submission_id: Optional[int] = None
    ) -> int:
        """Добавляет запись о прикрепленном файле."""
        now = datetime.now().isoformat()
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO task_files (task_id, submission_id, file_type, filename, stored_filename, file_size, mime_type, uploaded_by, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (task_id, submission_id, file_type, filename, stored_filename, file_size, mime_type, uploaded_by, now))
            conn.commit()
            return cursor.lastrowid

    def get_task_file(self, file_id: int) -> Optional[Dict[str, Any]]:
        """Возвращает метаданные файла по его ID."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM task_files WHERE id = ?", (file_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def delete_task_file(self, file_id: int) -> Optional[Dict[str, Any]]:
        """Удаляет файл из БД и возвращает его запись для удаления с диска."""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM task_files WHERE id = ?", (file_id,))
            row = cursor.fetchone()
            if not row:
                return None
            record = dict(row)
            cursor.execute("DELETE FROM task_files WHERE id = ?", (file_id,))
            conn.commit()
            return record

    def sync_tasks_from_schedule(self, group_name: str, lessons: List[Dict[str, Any]]) -> int:
        """
        Автоматически генерирует задания для практик и лабораторных из расписания группы.
        Не создает дубликаты. Поддерживает как DTO от мобильного приложения, так и сырые словари ДГТУ.
        """
        created_count = 0
        now = datetime.now()
        now_iso = now.isoformat()
        # Горизонт синхронизации для поддержки истории семестров (2 года)
        min_date = (now - timedelta(days=730)).strftime("%Y-%m-%d")

        with self._get_connection() as conn:
            cursor = conn.cursor()
            for l in lessons:
                raw_subject = l.get("subject") or l.get("дисциплина") or ""
                if not raw_subject:
                    continue
                subject = clean_subject_name(raw_subject)
                if not subject:
                    continue

                theme = (l.get("theme") or l.get("тема") or "").strip()
                date_str = l.get("date") or l.get("дата") or ""
                if "T" in date_str:
                    date_str = date_str.split("T")[0]

                # Фильтруем слишком старые архивные занятия
                if date_str and date_str < min_date:
                    continue

                num = l.get("num") or l.get("пара") or l.get("номер_занятия")
                if num:
                    try:
                        num = int(num)
                    except (ValueError, TypeError):
                        num = None

                l_type = l.get("lessonType") or l.get("тип") or ""
                if not l_type:
                    s_low = raw_subject.lower()
                    t_low = theme.lower()
                    color = (l.get("цвет") or l.get("color") or "").strip().lower()

                    # Теоретические лекции отсекаем
                    if any(k in t_low for k in ("лекция", "лекц.", "лек.", "введение", "основы", "теория", "история", "архитектура")):
                        continue

                    if any(p in s_low for p in ("(пр)", " пр.", "практик")) or any(p in t_low for p in ("практик", "кейс", "воркшоп", "моделирование", "расчет", "разработка")):
                        l_type = "Практика"
                    elif any(p in s_low for p in ("(лаб)", " лаб.", "лаборатор")) or "лаборатор" in t_low or color == "#004c3e":
                        l_type = "Лабораторная"
                    elif color in ("#5c6bc0", "#2196f3", "#009688", "#ff9800", "#ab47bc", "#fdd017", "#44c8c8"):
                        l_type = "Практика"
                    elif "семинар" in t_low:
                        l_type = "Семинар"
                    elif "проект" in s_low or "проект" in t_low:
                        l_type = "Проект"

                is_practice = any(p in l_type.lower() for p in ("практик", "лаборатор", "семинар", "проект"))
                if not is_practice:
                    continue

                if theme:
                    title = f"{l_type}: {theme}"
                elif num:
                    title = f"{l_type} №{num}"
                else:
                    title = f"{l_type}: {subject}"

                sem = l.get("semester") or self.resolve_semester_name(date_str)

                cursor.execute("""
                    SELECT id FROM tasks 
                    WHERE LOWER(TRIM(group_name)) = LOWER(TRIM(?)) 
                      AND LOWER(TRIM(subject)) = LOWER(TRIM(?))
                      AND (lesson_date = ? OR title = ?)
                """, (group_name, subject, date_str, title))

                exists = cursor.fetchone()
                if not exists:
                    cursor.execute("""
                        INSERT INTO tasks (group_name, subject, title, lesson_type, lesson_num, lesson_date, description, created_by, created_at, updated_at, semester)
                        VALUES (?, ?, ?, ?, ?, ?, ?, 'system_sync', ?, ?, ?)
                    """, (
                        group_name,
                        subject,
                        title,
                        l_type,
                        num,
                        date_str,
                        f"Создано автоматически из расписания на {date_str} (пара {num or '-'}).",
                        now_iso,
                        now_iso,
                        sem
                    ))
                    created_count += 1

            conn.commit()
        return created_count
