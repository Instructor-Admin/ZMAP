#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import re
import time
import json
import glob
import psycopg2
from io import StringIO

# =========================================================
# PostgreSQL
# =========================================================

DB_HOST = "IP"
DB_PORT = 5432
DB_NAME = "mydb"
DB_USER = "admin"
DB_PASS = "admin"

# =========================================================
# Files
# =========================================================

WATCH_DIR = "/root"
FILE_MASK = "temp_*.json"

CHUNK_SIZE = 50000
SLEEP_SEC = 2

OFFSET_FILE = "/root/temp_pg_offsets.json"

IP_RE = re.compile(r'\b(?:\d{1,3}\.){3}\d{1,3}\b')

# =========================================================


def log(msg):
    print(time.strftime("[%Y-%m-%d %H:%M:%S]"), msg, flush=True)


def connect_db():
    log("Подключение к PostgreSQL...")

    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )

    conn.autocommit = False

    log("PostgreSQL подключен")

    return conn


def load_offsets():
    if os.path.exists(OFFSET_FILE):
        try:
            with open(OFFSET_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}

    return {}


def save_offsets(offsets):
    tmp = OFFSET_FILE + ".tmp"

    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(offsets, f)

    os.replace(tmp, OFFSET_FILE)


def get_port(path):
    name = os.path.basename(path)

    m = re.match(r"temp_(\d+)\.json$", name)

    if not m:
        return None

    return int(m.group(1))


def ensure_table(conn, port):
    table = f"all_{port}"

    with conn.cursor() as cur:

        cur.execute(f"""
            CREATE TABLE IF NOT EXISTS {table} (
                id BIGSERIAL PRIMARY KEY,
                target TEXT UNIQUE NOT NULL,
                ip INET NOT NULL,
                port INTEGER NOT NULL,
                created_at TIMESTAMP DEFAULT NOW()
            );
        """)

        cur.execute(f"""
            CREATE INDEX IF NOT EXISTS idx_{table}_ip
            ON {table}(ip);
        """)

        cur.execute(f"""
            CREATE INDEX IF NOT EXISTS idx_{table}_target
            ON {table}(target);
        """)

    conn.commit()


def copy_chunk(conn, port, ips):

    if not ips:
        return 0

    table = f"all_{port}"
    temp_table = f"tmp_all_{port}"

    buf = StringIO()

    for ip in ips:
        buf.write(f"{ip}:{port}\t{ip}\t{port}\n")

    buf.seek(0)

    with conn.cursor() as cur:

        cur.execute(f"""
            CREATE TEMP TABLE {temp_table} (
                target TEXT,
                ip INET,
                port INTEGER
            ) ON COMMIT DROP;
        """)

        cur.copy_from(
            buf,
            temp_table,
            columns=("target", "ip", "port")
        )

        cur.execute(f"""
            INSERT INTO {table} (target, ip, port)
            SELECT target, ip, port
            FROM {temp_table}
            ON CONFLICT (target) DO NOTHING;
        """)

        inserted = cur.rowcount

    conn.commit()

    return inserted


def process_file(conn, path, offsets, waiting_state):

    port = get_port(path)

    if port is None:
        return

    ensure_table(conn, port)

    filesize = os.path.getsize(path)
    old_offset = int(offsets.get(path, 0))

    # файл пересоздан
    if filesize < old_offset:

        log(f"[{port}] файл пересоздан, offset сброшен")

        old_offset = 0
        offsets[path] = 0

        save_offsets(offsets)

        waiting_state[path] = False

    # новых данных нет
    if filesize <= old_offset:

        if not waiting_state.get(path):

            log(f"[{port}] WAITING FOR NEW IPS")

            waiting_state[path] = True

        return

    # если хвост очень маленький
    # и там нет IP -> конец JSON
    if filesize - old_offset < 1024:

        with open(path, "r", encoding="utf-8", errors="ignore") as f:

            f.seek(old_offset)

            tail = f.read()

        if not IP_RE.search(tail):

            if not waiting_state.get(path):

                log(f"[{port}] WAITING FOR NEW IPS")

                waiting_state[path] = True

            return

    waiting_state[path] = False

    rows = []

    processed = 0
    inserted_total = 0

    last_good_offset = old_offset

    log(f"[{port}] файл={path}")

    log(
        f"[{port}] "
        f"offset={old_offset:,} "
        f"filesize={filesize:,} "
        f"new_bytes={filesize - old_offset:,}"
    )

    with open(path, "r", encoding="utf-8", errors="ignore") as f:

        f.seek(old_offset)

        while True:

            line_start = f.tell()

            line = f.readline()

            if not line:
                break

            # строка еще пишется
            if not line.endswith("\n"):

                clean_tail = line.strip()

                # конец JSON
                if not IP_RE.search(clean_tail):

                    f.seek(line_start)

                    break

                # IP есть, но строка не дописана
                f.seek(line_start)

                if not waiting_state.get(path):

                    log(f"[{port}] WAITING FOR LINE FINISH")

                    waiting_state[path] = True

                break

            clean = line.strip()

            # конец JSON
            if clean in ("]", "}", "]}", "],", "},"):

                f.seek(line_start)

                break

            found = IP_RE.findall(clean)

            for ip in found:

                rows.append(ip)

                processed += 1

            last_good_offset = f.tell()

            if len(rows) >= CHUNK_SIZE:

                inserted = copy_chunk(conn, port, rows)

                inserted_total += inserted

                offsets[path] = last_good_offset

                save_offsets(offsets)

                log(
                    f"[{port}] chunk "
                    f"processed={processed:,} "
                    f"inserted_total={inserted_total:,} "
                    f"offset={last_good_offset:,}"
                )

                rows.clear()

        # остаток
        if rows:

            inserted = copy_chunk(conn, port, rows)

            inserted_total += inserted

            offsets[path] = last_good_offset

            save_offsets(offsets)

            log(
                f"[{port}] final_chunk "
                f"processed={processed:,} "
                f"inserted_total={inserted_total:,} "
                f"offset={last_good_offset:,}"
            )

    if processed > 0:

        duplicates = processed - inserted_total

        log(
            f"[{port}] DONE "
            f"processed={processed:,} "
            f"inserted={inserted_total:,} "
            f"duplicates={duplicates:,}"
        )

        if not waiting_state.get(path):

            log(f"[{port}] WAITING FOR NEW IPS")

            waiting_state[path] = True


def main():

    log("Старт слежения за temp_*.json")

    offsets = load_offsets()

    waiting_state = {}

    conn = connect_db()

    while True:

        try:

            files = sorted(
                glob.glob(os.path.join(WATCH_DIR, FILE_MASK))
            )

            if not files:

                log("Файлы temp_*.json не найдены")

            for path in files:

                try:

                    process_file(
                        conn,
                        path,
                        offsets,
                        waiting_state
                    )

                except psycopg2.Error as e:

                    log(f"[DB ERROR] {path}: {e}")

                    try:
                        conn.rollback()
                        conn.close()
                    except Exception:
                        pass

                    time.sleep(3)

                    conn = connect_db()

                except Exception as e:

                    log(f"[ERROR] {path}: {e}")

            time.sleep(SLEEP_SEC)

        except KeyboardInterrupt:

            log("Остановка")

            break

    try:
        conn.close()
    except Exception:
        pass


if __name__ == "__main__":
    main()
