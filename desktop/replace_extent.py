#!/usr/bin/env python3
"""Заменяет содержимое файла, лежащего на разделе одним непрерывным куском, не трогая
файловую систему: сначала проверяет, что на карте по этому адресу лежит ровно СТАРЫЙ файл,
потом пишет НОВЫЙ (того же размера) и проверяет запись чтением.

    sudo python3 -I replace_extent.py disk4 62534975488 НАЧАЛО_РАЗДЕЛА_МиБ СМЕЩЕНИЕ_БАЙТ старый новый
"""
import os
import subprocess
import sys

MIB = 1048576


def main():
    disk, expected, part_mib, offset, old_path, new_path = sys.argv[1:7]
    text = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in text or f"({expected} Bytes)" not in text:
        raise SystemExit("Это не та карта")
    old = open(old_path, "rb").read()
    new = open(new_path, "rb").read()
    if len(old) != len(new) or len(new) % 4096:
        raise SystemExit("Размеры не совпадают")
    pos = int(part_mib) * MIB + int(offset, 0)
    if pos % 4096 or pos + len(new) > int(expected):
        raise SystemExit("Неверный адрес")
    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    fd = os.open(f"/dev/r{disk}", os.O_RDWR)
    try:
        if os.pread(fd, len(old), pos) != old:
            raise SystemExit("На карте по этому адресу не тот файл. Ничего не записано.")
        os.pwrite(fd, new, pos)
        os.fsync(fd)
        if os.pread(fd, len(new), pos) != new:
            raise SystemExit("ОШИБКА: после записи данные не совпали")
    finally:
        os.close(fd)
    print(f"ГОТОВО: записано {len(new)} байт по адресу {pos:#x}")


if __name__ == "__main__":
    main()
