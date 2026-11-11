#!/usr/bin/env python3
"""Копирует раздел Windows 10 с карты в файл и запоминает контрольные суммы каждого МиБ,
чтобы потом записать обратно только изменённые участки (push_win.py).

    sudo python3 -I pull_win.py disk4 62534975488 папка
Карту только читает.
"""
import hashlib
import os
import subprocess
import sys

MIB = 1048576
START, SIZE = 10815 * MIB, 12288 * MIB


def check_card(disk, expected):
    text = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in text or f"({expected} Bytes)" not in text or "Removable" not in text:
        raise SystemExit("Это не карта из Hekate нужного размера")


def main():
    disk, expected, folder = sys.argv[1:4]
    check_card(disk, expected)
    os.makedirs(folder, exist_ok=True)
    image, sums = os.path.join(folder, "win.img"), os.path.join(folder, "win.sums")
    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    fd = os.open(f"/dev/r{disk}", os.O_RDONLY)
    with open(image, "wb") as out, open(sums, "w") as sums_file:
        for index in range(SIZE // MIB):
            block = os.pread(fd, MIB, START + index * MIB)
            if len(block) != MIB:
                raise SystemExit(f"Не прочитался МиБ {index}")
            out.write(block)
            sums_file.write(hashlib.sha1(block).hexdigest() + "\n")
            if index % 512 == 0:
                print(f"\r  скопировано {index} из {SIZE // MIB} МиБ", end="", flush=True)
    os.close(fd)
    uid = int(os.environ.get("SUDO_UID", os.getuid()))
    for path in (folder, image, sums):
        os.chown(path, uid, -1)
    print(f"\nГОТОВО: раздел скопирован в {image}")


if __name__ == "__main__":
    main()
