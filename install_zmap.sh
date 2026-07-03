#!/bin/bash

# Скрипт для обновления системы и установки sudo и pip
# Требует прав root (запуск через sudo или от root)

set -e  # Прерывать выполнение при ошибке

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "Ошибка: Скрипт должен запускаться с правами root (sudo)" 
   exit 1
fi

echo "=== Обновление списка пакетов ==="
apt update

echo "=== Установка sudo ==="
apt install sudo -y

echo "=== Установка pip (Python package manager) ==="
apt install pip -y

echo "=== Установка библиотеки для работы скрипта copy_db.py ==="
# Проверяем версию pip и выбираем правильную команду
pip_version=$(pip --version | awk '{print $2}' | cut -d'.' -f1)

if [ "$pip_version" -ge 22 ]; then
    pip install psycopg2-binary --break-system-packages
else
    pip install psycopg2-binary
fi

echo "=== Установка zmap ==="
apt install zmap -y

echo "=== Готово! ==="
echo "Проверка установленных версий:"
sudo --version | head -n1
pip --version
zmap --version
