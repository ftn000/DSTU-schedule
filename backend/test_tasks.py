import os
import unittest
from database import Database

class TestTasksModule(unittest.TestCase):
    def setUp(self):
        self.db_path = "test_tasks_temp.db"
        if os.path.exists(self.db_path):
            os.remove(self.db_path)
        self.db = Database(self.db_path)

    def tearDown(self):
        import gc
        gc.collect()
        if os.path.exists(self.db_path):
            try:
                os.remove(self.db_path)
            except Exception:
                pass

    def test_tasks_crud_and_submissions(self):
        # 1. Create task
        task_id = self.db.create_or_update_task(
            group_name="ВПР42",
            subject="Тестирование ПО",
            title="Практика №1: Юнит-тесты",
            lesson_type="Практика",
            lesson_num=2,
            lesson_date="2026-10-01",
            description="Написать тесты для backend",
            deadline="2026-10-10",
            created_by="347338"
        )
        self.assertGreater(task_id, 0)

        # 2. Add task file (методичка)
        f_id = self.db.add_task_file(
            task_id=task_id,
            file_type="task_attachment",
            filename="manual.pdf",
            stored_filename="manual_123.pdf",
            file_size=1024,
            mime_type="application/pdf",
            uploaded_by="347338"
        )
        self.assertGreater(f_id, 0)

        # 3. Add student submission & submission file
        sub_id = self.db.save_submission(
            task_id=task_id,
            student_id="347338",
            status="in_progress",
            text_solution="Тесты почти готовы"
        )
        self.assertGreater(sub_id, 0)

        sub_f_id = self.db.add_task_file(
            task_id=task_id,
            submission_id=sub_id,
            file_type="submission_attachment",
            filename="solution.zip",
            stored_filename="sol_123.zip",
            file_size=2048,
            mime_type="application/zip",
            uploaded_by="347338"
        )
        self.assertGreater(sub_f_id, 0)

        # 4. Query tasks with student_id
        tasks = self.db.get_tasks("ВПР42", student_id="347338")
        self.assertEqual(len(tasks), 1)
        t = tasks[0]
        self.assertEqual(t["title"], "Практика №1: Юнит-тесты")
        self.assertEqual(len(t["task_files"]), 1)
        self.assertEqual(t["task_files"][0]["filename"], "manual.pdf")
        self.assertIsNotNone(t["submission"])
        self.assertEqual(t["submission"]["status"], "in_progress")
        self.assertEqual(t["submission"]["text_solution"], "Тесты почти готовы")
        self.assertEqual(len(t["submission"]["files"]), 1)
        self.assertEqual(t["submission"]["files"][0]["filename"], "solution.zip")

        # 5. Sync from schedule
        mock_schedule = [
            {
                "lessonType": "Практика",
                "subject": "Базы данных",
                "theme": "Индексы и транзакции",
                "date": "2026-10-05T08:30:00",
                "num": 1
            },
            {
                "lessonType": "Лекция", # Should be skipped
                "subject": "Базы данных",
                "theme": "Теория нормализации",
                "date": "2026-10-05T10:15:00",
                "num": 2
            }
        ]
        count = self.db.sync_tasks_from_schedule("ВПР42", mock_schedule)
        self.assertEqual(count, 1)

        tasks_after_sync = self.db.get_tasks("ВПР42", student_id="347338")
        self.assertEqual(len(tasks_after_sync), 2)

        # 6. Delete task
        deleted_files = self.db.delete_task(task_id)
        self.assertIn("manual_123.pdf", deleted_files)
        self.assertIn("sol_123.zip", deleted_files)

        tasks_final = self.db.get_tasks("ВПР42")
        self.assertEqual(len(tasks_final), 1)

if __name__ == "__main__":
    unittest.main()
