@echo off
chcp 65001 > nul

echo ========================================================
echo  Сборка релиза Android APK (ДГТУ Расписание)
echo ========================================================
echo.

set "SCRIPT_DIR=%~dp0"
set "MOBILE_DIR=%SCRIPT_DIR%mobile"
set "FLUTTER_CMD="

:: 1. Проверка в PATH
where flutter.bat >nul 2>nul
if %ERRORLEVEL% equ 0 (
    set "FLUTTER_CMD=flutter.bat"
    goto :FLUTTER_FOUND
)
where flutter >nul 2>nul
if %ERRORLEVEL% equ 0 (
    set "FLUTTER_CMD=flutter"
    goto :FLUTTER_FOUND
)

:: 2. Проверка переменных окружения
if defined FLUTTER_HOME if exist "%FLUTTER_HOME%\bin\flutter.bat" (
    set "FLUTTER_CMD=%FLUTTER_HOME%\bin\flutter.bat"
    goto :FLUTTER_FOUND
)
if defined FLUTTER_ROOT if exist "%FLUTTER_ROOT%\bin\flutter.bat" (
    set "FLUTTER_CMD=%FLUTTER_ROOT%\bin\flutter.bat"
    goto :FLUTTER_FOUND
)

:: 3. Проверка типовых путей установки
if exist "C:\flutter\bin\flutter.bat" set "FLUTTER_CMD=C:\flutter\bin\flutter.bat" & goto :FLUTTER_FOUND
if exist "C:\src\flutter\bin\flutter.bat" set "FLUTTER_CMD=C:\src\flutter\bin\flutter.bat" & goto :FLUTTER_FOUND
if exist "C:\tools\flutter\bin\flutter.bat" set "FLUTTER_CMD=C:\tools\flutter\bin\flutter.bat" & goto :FLUTTER_FOUND
if exist "C:\dev\flutter\bin\flutter.bat" set "FLUTTER_CMD=C:\dev\flutter\bin\flutter.bat" & goto :FLUTTER_FOUND
if exist "D:\flutter\bin\flutter.bat" set "FLUTTER_CMD=D:\flutter\bin\flutter.bat" & goto :FLUTTER_FOUND
if exist "D:\src\flutter\bin\flutter.bat" set "FLUTTER_CMD=D:\src\flutter\bin\flutter.bat" & goto :FLUTTER_FOUND
if exist "E:\flutter\bin\flutter.bat" set "FLUTTER_CMD=E:\flutter\bin\flutter.bat" & goto :FLUTTER_FOUND
if exist "%LOCALAPPDATA%\flutter\bin\flutter.bat" set "FLUTTER_CMD=%LOCALAPPDATA%\flutter\bin\flutter.bat" & goto :FLUTTER_FOUND
if exist "%LOCALAPPDATA%\Programs\flutter\bin\flutter.bat" set "FLUTTER_CMD=%LOCALAPPDATA%\Programs\flutter\bin\flutter.bat" & goto :FLUTTER_FOUND
if exist "%USERPROFILE%\flutter\bin\flutter.bat" set "FLUTTER_CMD=%USERPROFILE%\flutter\bin\flutter.bat" & goto :FLUTTER_FOUND
if exist "%USERPROFILE%\src\flutter\bin\flutter.bat" set "FLUTTER_CMD=%USERPROFILE%\src\flutter\bin\flutter.bat" & goto :FLUTTER_FOUND
if exist "%USERPROFILE%\fvm\default\bin\flutter.bat" set "FLUTTER_CMD=%USERPROFILE%\fvm\default\bin\flutter.bat" & goto :FLUTTER_FOUND
if exist "%USERPROFILE%\scoop\apps\flutter\current\bin\flutter.bat" set "FLUTTER_CMD=%USERPROFILE%\scoop\apps\flutter\current\bin\flutter.bat" & goto :FLUTTER_FOUND

:FLUTTER_NOT_FOUND
echo [ОШИБКА] Flutter SDK не найден в PATH и стандартных папках установки.
echo.
echo Для сборки APK установите Flutter:
echo  1. Скачайте: https://docs.flutter.dev/get-started/install/windows
echo  2. Добавьте путь к bin в системную переменную PATH
echo     (или укажите переменную FLUTTER_HOME).
echo.
set /p USER_PATH="Укажите путь к flutter.bat вручную (или нажмите Enter для выхода): "
if not "%USER_PATH%"=="" (
    set "USER_PATH=%USER_PATH:"=%"
    if exist "%USER_PATH%" (
        set "FLUTTER_CMD=%USER_PATH%"
        goto :FLUTTER_FOUND
    )
)
echo.
echo Сборка отменена.
pause
exit /b 1

:FLUTTER_FOUND
echo [OK] Используется Flutter: %FLUTTER_CMD%
echo.

if not exist "%MOBILE_DIR%" (
    echo [ОШИБКА] Папка "%MOBILE_DIR%" не найдена!
    pause
    exit /b 1
)

cd /d "%MOBILE_DIR%"

:: Проверка и подготовка .env
set "DART_DEFINES="
if exist ".env" (
    echo [INFO] Найден файл .env, параметры внедряются в сборку.
    set "DART_DEFINES=--dart-define-from-file=.env"
) else (
    echo [INFO] Файл .env не найден, используется API_URL по умолчанию.
)

echo.
echo [1/3] Загрузка зависимостей (flutter pub get)...
call "%FLUTTER_CMD%" pub get
if %ERRORLEVEL% neq 0 (
    echo [ОШИБКА] Не удалось загрузить зависимости flutter pub get!
    pause
    exit /b %ERRORLEVEL%
)

echo.
echo [2/3] Компиляция Release APK...
call "%FLUTTER_CMD%" build apk --release %DART_DEFINES%
if %ERRORLEVEL% neq 0 (
    echo.
    echo [ОШИБКА] Сборка APK завершилась с ошибкой!
    echo Выполните "%FLUTTER_CMD% doctor" для проверки настройки Android SDK и Java.
    pause
    exit /b %ERRORLEVEL%
)

set "SOURCE_APK=build\app\outputs\flutter-apk\app-release.apk"
set "TARGET_APK=%SCRIPT_DIR%DSTU-schedule.apk"

if not exist "%SOURCE_APK%" (
    echo [ОШИБКА] Файл сборки "%SOURCE_APK%" не найден!
    pause
    exit /b 1
)

echo.
echo [3/3] Копирование готового APK в корень проекта...
copy /Y "%SOURCE_APK%" "%TARGET_APK%" > nul

echo.
echo ========================================================
echo  Сборка успешно завершена!
echo  Готовый файл: %TARGET_APK%
echo ========================================================
echo.
pause
