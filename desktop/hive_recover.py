#!/usr/bin/env python3
"""Доводит куст реестра, недописанный из-за выключения, до целого состояния:
применяет его журналы (.LOG1/.LOG2) и делает заголовок «чистым».

    python3 hive_recover.py SYSTEM SYSTEM.LOG1 SYSTEM.LOG2 выход
Нужен regipy. Если куст и так чистый, просто копирует его.
"""
import os
import shutil
import struct
import sys

from regipy.recovery import apply_transaction_logs


def sequences(path):
    with open(path, "rb") as f:
        head = f.read(512)
    if head[:4] != b"regf":
        return None
    return struct.unpack_from("<II", head, 4)


def mark_clean(path, seq):
    with open(path, "r+b") as f:
        head = bytearray(f.read(512))
        struct.pack_into("<II", head, 4, seq, seq)
        checksum = 0
        for (word,) in struct.iter_unpack("<I", bytes(head[:508])):
            checksum ^= word
        checksum = {0: 1, 0xFFFFFFFF: 0xFFFFFFFE}.get(checksum, checksum)
        struct.pack_into("<I", head, 508, checksum)
        f.seek(0)
        f.write(head)


def main():
    hive, log1, log2, out = sys.argv[1:5]
    primary, secondary = sequences(hive)
    if primary == secondary:
        shutil.copyfile(hive, out)
        print(f"{os.path.basename(hive)}: чистый ({primary})")
        return
    # Нужны только журналы не старше последней полной записи куста (как делает Windows).
    logs = [log for log in (log1, log2)
            if os.path.getsize(log) >= 512 and sequences(log) and sequences(log)[0] >= secondary]
    logs.sort(key=lambda log: sequences(log)[0])
    if not logs:
        raise SystemExit(f"{hive}: куст недописан, а журналов нет")
    newest = max(primary, secondary, *(sequences(log)[1] for log in logs))
    if len(logs) == 2:
        _, pages = apply_transaction_logs(hive, logs[1], logs[0], out)
    else:
        _, pages = apply_transaction_logs(hive, logs[0], None, out)
    mark_clean(out, newest + 1)
    print(f"{os.path.basename(hive)}: {primary}/{secondary}, восстановлено страниц {pages}, "
          f"теперь {sequences(out)}")


if __name__ == "__main__":
    main()
