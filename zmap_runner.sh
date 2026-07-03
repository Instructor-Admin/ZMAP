#!/bin/bash
# fortinet_mass_scan.sh — Параллельное сканирование + автооптимизация + ETA
# Имена файлов: temp_${port}.json

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ============================================
# КОНФИГ
# ============================================
WHITELIST="./ranges.txt"
BANDWIDTH="70M"
PROBES=1
RETRIES=0
COOLDOWN=3

PORTS=(443 10443 8443 4433 4443 9443 444 4444 4434 7443 6443 3443)

# ============================================
# ПРОВЕРКА ЗАВИСИМОСТЕЙ
# ============================================
for cmd in zmap python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}[!] $cmd не найден. apt install $cmd -y${NC}"
        exit 1
    fi
done

# ============================================
# АВТООПТИМИЗАЦИЯ
# ============================================
echo -e "${YELLOW}[*] Оптимизация системы...${NC}"

CURRENT_RMEM=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
CURRENT_WMEM=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)

if [ "$CURRENT_RMEM" -lt 134217728 ] 2>/dev/null; then
    sysctl -w net.core.rmem_max=134217728 >/dev/null 2>&1 && \
        echo -e "    ${GREEN}rmem_max: $CURRENT_RMEM → 134217728${NC}" || \
        echo -e "    ${YELLOW}rmem_max: $CURRENT_RMEM (нужен root)${NC}"
else
    echo -e "    ${GREEN}rmem_max: $CURRENT_RMEM (OK)${NC}"
fi

if [ "$CURRENT_WMEM" -lt 134217728 ] 2>/dev/null; then
    sysctl -w net.core.wmem_max=134217728 >/dev/null 2>&1 && \
        echo -e "    ${GREEN}wmem_max: $CURRENT_WMEM → 134217728${NC}" || \
        echo -e "    ${YELLOW}wmem_max: $CURRENT_WMEM (нужен root)${NC}"
else
    echo -e "    ${GREEN}wmem_max: $CURRENT_WMEM (OK)${NC}"
fi

sysctl -w net.core.netdev_max_backlog=250000 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_rmem='4096 87380 134217728' >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_wmem='4096 65536 134217728' >/dev/null 2>&1 || true

CORES=$(nproc)
THREADS=$((CORES / 2))
[ "$THREADS" -lt 1 ] && THREADS=1
[ "$THREADS" -gt 4 ] && THREADS=4

echo -e "    CPU: ${GREEN}$CORES${NC} ядер, потоков на сканер: ${GREEN}$THREADS${NC}"

if [ ! -f "$WHITELIST" ]; then
    echo -e "${RED}[!] Whitelist не найден: $WHITELIST${NC}"
    exit 1
fi

TOTAL_RANGES=$(wc -l < "$WHITELIST")
echo -e "    Диапазонов: ${GREEN}$TOTAL_RANGES${NC}"

# Подсчитываем общее количество IP для ETA
TOTAL_IPS=$(python3 -c "
total = 0
with open('$WHITELIST') as f:
    for line in f:
        if '/' in line:
            mask = int(line.strip().split('/')[1])
            total += (1 << (32 - mask))
print(total)
" 2>/dev/null || echo 0)

echo -e "    Всего IP: ${GREEN}$(printf "%'d" $TOTAL_IPS)${NC}"
echo ""

# ============================================
# ПАРАЛЛЕЛЬНОЕ СКАНИРОВАНИЕ
# ============================================
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  ЗАПУСК ${#PORTS[@]} СКАНЕРОВ${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""

START_TIME=$(date +%s)
PIDS=()

for port in "${PORTS[@]}"; do
    OUTPUT="temp_${port}.json"
    
    echo -e "${CYAN}[*] Порт $port → $OUTPUT${NC}"
    
    (
        echo '{"port":'$port',"ips":[' > "$OUTPUT"
        
        zmap -p "$port" \
             -w "$WHITELIST" \
             -B "$BANDWIDTH" \
             --sender-threads="$THREADS" \
             --probes="$PROBES" \
             --retries="$RETRIES" \
             --cooldown-time="$COOLDOWN" \
             -o - 2>"temp_${port}.log" | \
            awk '{print "\""$1"\","}' | sed '$ s/,$//' >> "$OUTPUT"
        
        echo ']}' >> "$OUTPUT"
        
        if [ "$(wc -l < "$OUTPUT")" -le 3 ]; then
            echo '{"port":'$port',"ips":[]}' > "$OUTPUT"
        fi
    ) &
    
    PIDS+=($!)
done

echo ""
echo -e "${YELLOW}[*] Сканеры запущены (PID: ${PIDS[*]})${NC}"
echo ""

# ============================================
# МОНИТОРИНГ С ETA
# ============================================
trap 'echo -e "\n${YELLOW}[!] Мониторинг остановлен. Сканеры продолжают.${NC}"; exit 0' INT

# Сохраняем историю скорости для точного ETA
declare -A LAST_COUNT
declare -A LAST_TIME
for port in "${PORTS[@]}"; do
    LAST_COUNT[$port]=0
    LAST_TIME[$port]=$START_TIME
done

while true; do
    clear
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  МОНИТОРИНГ (Ctrl+C — выйти, сканеры продолжат)${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    RUNNING=0
    TOTAL=0
    TOTAL_SPEED=0
    
    for i in "${!PORTS[@]}"; do
        port="${PORTS[$i]}"
        pid="${PIDS[$i]}"
        output="temp_${port}.json"
        
        if kill -0 "$pid" 2>/dev/null; then
            STATUS="${GREEN}▶${NC}"
            RUNNING=$((RUNNING + 1))
        else
            STATUS="${CYAN}✓${NC}"
        fi
        
        if [ -f "$output" ]; then
            COUNT=$(grep -cE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' "$output" 2>/dev/null) || COUNT=0
            TOTAL=$((TOTAL + COUNT))
            
            # Считаем скорость для этого порта
            PORT_ELAPSED=$((CURRENT_TIME - LAST_TIME[$port]))
            if [ $PORT_ELAPSED -gt 0 ]; then
                PORT_SPEED=$(( (COUNT - LAST_COUNT[$port]) / PORT_ELAPSED ))
                TOTAL_SPEED=$((TOTAL_SPEED + PORT_SPEED))
                printf "  ${STATUS} Порт %-6s | %-8s IP | %-6s IP/s\n" "$port" "$COUNT" "$PORT_SPEED"
            else
                printf "  ${STATUS} Порт %-6s | %-8s IP\n" "$port" "$COUNT"
            fi
            
            LAST_COUNT[$port]=$COUNT
            LAST_TIME[$port]=$CURRENT_TIME
        else
            printf "  ${STATUS} Порт %-6s | %-8s IP\n" "$port" "0"
        fi
    done
    
    echo ""
    
    # ETA расчет
    ELAPSED_FMT=$(printf "%dч %02dм %02dс" $((ELAPSED/3600)) $(((ELAPSED%3600)/60)) $((ELAPSED%60)))
    
    if [ $TOTAL -gt 0 ] && [ $TOTAL_SPEED -gt 0 ]; then
        # Процент завершения (по времени, грубо)
        PROGRESS=$(echo "scale=1; $TOTAL * 100 / ($TOTAL + ($TOTAL_SPEED * $ELAPSED))" | bc 2>/dev/null || echo "?")
        
        # Оставшееся время
        REMAINING_IPS=$((TOTAL_IPS - TOTAL * (TOTAL_IPS / (TOTAL + 1))))  # грубая оценка оставшихся IP
        REMAINING_SEC=$(( (TOTAL_IPS - (TOTAL * (TOTAL_IPS / (TOTAL + TOTAL_SPEED)))) / (TOTAL_SPEED + 1) ))
        REMAINING_SEC=$(( REMAINING_SEC / RUNNING ))  # делим на активные сканеры
        
        if [ $REMAINING_SEC -gt 0 ] && [ $REMAINING_SEC -lt 86400 ]; then
            ETA_FMT=$(printf "%dч %02dм %02dс" $((REMAINING_SEC/3600)) $(((REMAINING_SEC%3600)/60)) $((REMAINING_SEC%60)))
            ETA_TIME=$(date -d "+${REMAINING_SEC} seconds" "+%H:%M:%S" 2>/dev/null || echo "~${ETA_FMT}")
        else
            ETA_FMT="расчёт..."
            ETA_TIME="расчёт..."
        fi
    else
        PROGRESS="?"
        ETA_FMT="расчёт..."
        ETA_TIME="расчёт..."
    fi
    
    echo -e "  Найдено всего:    ${GREEN}${TOTAL}${NC}"
    echo -e "  Суммарная скор.:  ${GREEN}${TOTAL_SPEED}${NC} IP/s"
    echo -e "  Активных сканеров: ${GREEN}${RUNNING}/${#PORTS[@]}${NC}"
    echo -e "  Прошло:           ${CYAN}${ELAPSED_FMT}${NC}"
    echo -e "  Осталось:         ${YELLOW}${ETA_FMT}${NC}"
    echo -e "  Завершение:       ${MAGENTA}${ETA_TIME}${NC}"
    
    if [ "$RUNNING" -eq 0 ]; then
        echo ""
        echo -e "${GREEN}[+] Все сканеры завершены!${NC}"
        break
    fi
    
    sleep 5
done

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
TOTAL_TIME_FMT=$(printf "%dч %02dм %02dс" $((TOTAL_TIME/3600)) $(((TOTAL_TIME%3600)/60)) $((TOTAL_TIME%60)))

for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

echo ""

# ============================================
# ОБЪЕДИНЕНИЕ
# ============================================
echo -e "${YELLOW}[*] Объединение результатов...${NC}"

python3 << PYEOF
import json
import os

ports = [443, 10443, 8443, 4433, 4443, 9443, 444, 4444, 4434, 7443, 6443, 3443]
all_ips = set()
total_found = 0

print("=== РЕЗУЛЬТАТЫ ===")
for port in ports:
    filename = f"temp_{port}.json"
    if os.path.exists(filename):
        try:
            with open(filename) as f:
                data = json.load(f)
            ips = [ip for ip in data['ips'] if ip]
            count = len(ips)
            total_found += count
            all_ips.update(ips)
            print(f"  temp_{port}.json: {count} IP")
        except:
            print(f"  temp_{port}.json: ошибка")
    else:
        print(f"  temp_{port}.json: не создан")

print(f"\n  Всего записей: {total_found}")
print(f"  Уникальных IP: {len(all_ips)}")

with open("all_unique_ips.txt", "w") as f:
    for ip in sorted(all_ips):
        f.write(ip + "\n")

print(f"\n[+] Уникальные IP: all_unique_ips.txt")
PYEOF

echo ""

# ============================================
# ФИНАЛ
# ============================================
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  ГОТОВО${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "Файлы портов:"
for port in "${PORTS[@]}"; do
    if [ -f "temp_${port}.json" ]; then
        COUNT=$(python3 -c "import json; print(len(json.load(open('temp_${port}.json'))['ips']))" 2>/dev/null || echo 0)
        echo -e "  ${CYAN}temp_${port}.json${NC} — $COUNT IP"
    fi
done
echo ""
echo -e "Уникальные IP: ${CYAN}all_unique_ips.txt${NC} ($(wc -l < all_unique_ips.txt 2>/dev/null || echo 0) IP)"
echo -e "Общее время:   ${GREEN}${TOTAL_TIME_FMT}${NC}"
echo ""
echo -e "${YELLOW}[*] Для проверки Fortinet:${NC}"
echo -e "  ${CYAN}curl -sk https://IP:8443/login | grep -i fortinet${NC}"
