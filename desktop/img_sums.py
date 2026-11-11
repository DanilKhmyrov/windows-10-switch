#!/usr/bin/env python3
"""Контрольные суммы образа по МиБ и запись на карту только изменившихся МиБ.

    python3 img_sums.py sums образ.img суммы.txt
    sudo python3 -I img_sums.py push disk4 62534975488 образ.img суммы.txt НАЧАЛО_МиБ
(push пишет МиБ, у которых сумма отличается от сохранённой, и проверяет запись чтением.)
"""
import hashlib
import os
import subprocess
import sys

MIB = 1048576


def block_sums(path):
    size = os.path.getsize(path)
    out = []
    with open(path, "rb") as f:
        for _ in range(size // MIB):
            out.append(hashlib.sha1(f.read(MIB)).hexdigest())
    return out


def main():
    if sys.argv[1] == "sums":
        image, sums = sys.argv[2:4]
        open(sums, "w").write("\n".join(block_sums(image)) + "\n")
        print("суммы:", sums)
        return
    disk, expected, image, sums, start_mib = sys.argv[2:7]
    start = int(start_mib) * MIB
    text = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in text or f"({expected} Bytes)" not in text:
        raise SystemExit("Это не та карта")
    old = open(sums).read().split()
    size = os.path.getsize(image)
    if len(old) != size // MIB or start + size > int(expected):
        raise SystemExit("Суммы или размер не сходятся")
    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    fd = os.open(f"/dev/r{disk}", os.O_RDWR)
    changed = 0
    with open(image, "rb") as src:
        for i in range(size // MIB):
            block = src.read(MIB)
            if hashlib.sha1(block).hexdigest() == old[i]:
                continue
            os.pwrite(fd, block, start + i * MIB)
            if os.pread(fd, MIB, start + i * MIB) != block:
                raise SystemExit(f"ОШИБКА: МиБ {i} не совпал после записи")
            changed += 1
    os.fsync(fd)
    os.close(fd)
    print(f"ГОТОВО: записано изменённых МиБ: {changed}")


if __name__ == "__main__":
    main()
