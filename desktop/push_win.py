#!/usr/bin/env python3
"""Записывает на карту только те МиБ раздела Windows 10, что изменились после pull_win.py,
и проверяет запись чтением.

    sudo python3 -I push_win.py disk4 62534975488 папка
"""
import hashlib
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pull_win import MIB, SIZE, START, check_card  # noqa: E402


def main():
    disk, expected, folder = sys.argv[1:4]
    check_card(disk, expected)
    image, sums = os.path.join(folder, "win.img"), os.path.join(folder, "win.sums")
    if os.path.getsize(image) != SIZE:
        raise SystemExit("Неверный размер образа")
    old = open(sums).read().split()
    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    fd = os.open(f"/dev/r{disk}", os.O_RDWR)
    changed = 0
    with open(image, "rb") as source:
        for index in range(SIZE // MIB):
            block = source.read(MIB)
            if hashlib.sha1(block).hexdigest() == old[index]:
                continue
            if hashlib.sha1(os.pread(fd, MIB, START + index * MIB)).hexdigest() != old[index]:
                raise SystemExit(f"МиБ {index} на карте изменился после копирования, не пишу")
            os.pwrite(fd, block, START + index * MIB)
            if os.pread(fd, MIB, START + index * MIB) != block:
                raise SystemExit(f"ОШИБКА: МиБ {index} не совпал после записи")
            changed += 1
    os.fsync(fd)
    os.close(fd)
    print(f"ГОТОВО: записано изменённых МиБ: {changed}")


if __name__ == "__main__":
    main()
