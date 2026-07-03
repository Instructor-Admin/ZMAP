#!/bin/bash

echo "=== НАСТРОЙКА ==="
bash install_zmap.sh

echo "[$(date)] Запуск zmap_runner.sh ..."
nohup bash zmap_runner.sh > zmap_runner.log 2>&1 &
echo $! > zmap_runner.pid
echo "=== zmap_runner.log ==="
tail zmap_runner.log

sleep 10

echo "[$(date)] Запуск copy_db.py ..."
nohup python3 copy_db.py > copy_db.log 2>&1 &
echo $! > copy_db.pid

echo "[$(date)] Готово. PID zmap_runner: $(cat zmap_runner.pid), PID copy_db: $(cat copy_db.pid)"
