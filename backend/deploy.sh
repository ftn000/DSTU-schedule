#!/bin/bash
# Скрипт автоматического развертывания бэкенда ДГТУ Расписания на VPS (Ubuntu 22.04 / 24.04)

set -e

echo "=== [1/5] Обновление пакетов и установка зависимостей ==="
apt update -y
apt install -y python3 python3-pip python3-venv git nginx

echo "=== [2/5] Настройка виртуального окружения Python ==="
cd "$(dirname "$0")"
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r requirements.txt

echo "=== [3/5] Регистрация и запуск systemd-сервиса ==="
cp dstu-backend.service /etc/systemd/system/dstu-backend.service
systemctl daemon-reload
systemctl enable dstu-backend
systemctl restart dstu-backend

echo "=== [4/5] Настройка Nginx ==="
cat << 'EOF' > /etc/nginx/sites-available/dstu
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/dstu /etc/nginx/sites-enabled/dstu
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

echo "=== [5/5] Проверка статуса ==="
systemctl status dstu-backend --no-pager

echo ""
echo "🎉 Сервер успешно развернут и доступен на 80 порту!"
echo "Проверьте в браузере: http://<IP_ВАШЕГО_СЕРВЕРА>/api/health"
