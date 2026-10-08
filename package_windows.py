import os
import shutil
import zipfile

def package_windows():
    project_root = r"c:\GitHub\DSTU-schedule"
    release_dir = os.path.join(project_root, "mobile", "build", "windows", "x64", "runner", "Release")
    stage_dir = os.path.join(project_root, "mobile", "build", "windows_package", "DSTU-schedule")
    zip_path = os.path.join(project_root, "backend", "DSTU-schedule-windows.zip")

    if os.path.exists(stage_dir):
        shutil.rmtree(stage_dir)
    os.makedirs(stage_dir, exist_ok=True)

    # 1. Copy release directory
    shutil.copytree(release_dir, stage_dir, dirs_exist_ok=True)

    # Remove stale kernel_blob.bin if present in staging
    kernel_blob = os.path.join(stage_dir, "data", "flutter_assets", "kernel_blob.bin")
    if os.path.exists(kernel_blob):
        os.remove(kernel_blob)
        print("Removed stale debug kernel_blob.bin")

    # 2. Copy dstu_schedule.exe -> DSTU-schedule.exe
    shutil.copy2(os.path.join(stage_dir, "dstu_schedule.exe"), os.path.join(stage_dir, "DSTU-schedule.exe"))

    # 3. Copy MSVC Runtime DLLs
    sys32 = r"C:\Windows\System32"
    vc_dlls = [
        "msvcp140.dll",
        "msvcp140_1.dll",
        "msvcp140_2.dll",
        "msvcp140_atomic_wait.dll",
        "msvcp140_codecvt_ids.dll",
        "vcruntime140.dll",
        "vcruntime140_1.dll",
        "vcruntime140_threads.dll"
    ]
    copied_dlls = []
    for dll in vc_dlls:
        src = os.path.join(sys32, dll)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(stage_dir, dll))
            copied_dlls.append(dll)
    print("Copied VC++ runtime DLLs:", copied_dlls)

    # 4. Create batch launchers
    bat_content = '@echo off\r\nstart "" "%~dp0dstu_schedule.exe"\r\n'
    with open(os.path.join(stage_dir, "Запустить_расписание.bat"), "w", encoding="cp866") as f:
        f.write(bat_content)
    with open(os.path.join(stage_dir, "Run_DSTU_Schedule.bat"), "w", encoding="ascii") as f:
        f.write(bat_content)

    # 5. Create README.txt
    readme_content = """============================================================
  ДГТУ Расписание — Десктопная версия для Windows (x64)
  Версия: 1.8.4
============================================================

Быстрый запуск:
1. Распакуйте этот архив в любую папку (например, в Загрузки или на Рабочий стол).
2. Запустите файл "dstu_schedule.exe" (или "DSTU-schedule.exe", либо "Запустить_расписание.bat").
3. Для удобства можно кликнуть правой кнопкой мыши по dstu_schedule.exe -> "Отправить" -> "Рабочий стол (создать ярлык)".

Особенности портативной версии:
• Работает без необходимости предварительной установки.
• Включает все необходимые библиотеки среды выполнения Windows x64 (MSVC Runtime).
• Полная поддержка модулей расписания, уведомлений и раздела "Задания и практики".

Telegram-бот: @dstu_schedule_notify_bot
============================================================
"""
    with open(os.path.join(stage_dir, "README.txt"), "w", encoding="utf-8") as f:
        f.write(readme_content)

    # 6. Create zip archive
    if os.path.exists(zip_path):
        os.remove(zip_path)

    parent_dir = os.path.dirname(stage_dir)
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zipf:
        for root, dirs, files in os.walk(stage_dir):
            for file in files:
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, parent_dir)
                zipf.write(full_path, rel_path)

    size_mb = os.path.getsize(zip_path) / (1024 * 1024)
    print(f"Archive created successfully: {zip_path} ({size_mb:.2f} MB)")

if __name__ == "__main__":
    package_windows()
