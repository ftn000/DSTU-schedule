@echo off
chcp 65001 > nul
echo ========================================================
echo  Сборка релиза Android APK (ДГТУ Расписание)
echo ========================================================

cd /d "%~dp0mobile"

echo [1/2] Компиляция Release APK с параметрами из mobile/.env...
call C:\flutter\bin\flutter.bat build apk --release --dart-define-from-file=.env

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ❌ Ошибка сборки APK!
    pause
    exit /b %ERRORLEVEL%
)

echo [2/2] Копирование готового APK в корень проекта...
copy /Y "build\app\outputs\flutter-apk\app-release.apk" "..\DSTU-schedule.apk" > nul

echo.
echo ========================================================
echo  🎉 Сборка успешно завершена!
echo  Готовый файл: DSTU-schedule.apk
echo ========================================================
echo.
pause
