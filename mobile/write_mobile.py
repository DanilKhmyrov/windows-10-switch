#!/usr/bin/env python3
"""Пишет разделы телефона на карту и продлевает цепочку логических разделов.

    sudo python3 -I write_mobile.py disk4 62534975488 disk.img mainos.img phone.ffu
Перед записью проверяет, что перед ним карта из Hekate нужного размера.
"""
import os
import struct
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "windows"))
import ffu_extract  # noqa: E402

MIB = 1048576
SECTOR = 512
EXT = 2016 * MIB
IOT_DATA = 2024 * MIB
IOT_DATA_SIZE = 1575 * MIB + 640 * 1024
MAIN_EBR, MAIN_START, MAIN_SIZE = 3600 * MIB, 3601 * MIB, 1863 * MIB
DATA_EBR, DATA_START, DATA_SIZE = 5464 * MIB, 5465 * MIB, 5349 * MIB
FFU_DATA = 2048 * MIB
FFU_DATA_SIZE = 5349 * MIB
EXT_SIZE = DATA_START + DATA_SIZE - EXT
TYPE_NTFS, TYPE_EXT = 0x07, 0x05


def s(value):
    return value // SECTOR


def entry(kind, start, size):
    return bytes(4) + bytes([kind]) + bytes(3) + struct.pack("<II", s(start), s(size))


def ebr(first, link=None):
    data = bytearray(512)
    data[446:462] = first
    if link:
        data[462:478] = link
    data[510:512] = b"\x55\xaa"
    return bytes(data)


def info(disk):
    return subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout


def write_at(fd, offset, data):
    os.pwrite(fd, data, offset)


def copy(fd, source, source_offset, target, size, label):
    print(label)
    with open(source, "rb") as src:
        src.seek(source_offset)
        done = 0
        while done < size:
            block = src.read(min(MIB, size - done))
            if not block or len(block) % SECTOR:
                raise SystemExit(f"Неожиданный конец файла {source}")
            os.pwrite(fd, block, target + done)
            done += len(block)


def main():
    disk, expected, disk_img, mainos, ffu_path = sys.argv[1:6]
    text = info(disk)
    if "SD RAW" not in text or f"({expected} Bytes)" not in text or "Removable" not in text:
        raise SystemExit("Это не карта из Hekate нужного размера")
    if os.path.getsize(mainos) != MAIN_SIZE:
        raise SystemExit("Неверный размер образа MainOS телефона")
    if DATA_START + DATA_SIZE > int(expected):
        raise SystemExit("Разметка не помещается на карту")
    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    fd = os.open(f"/dev/r{disk}", os.O_RDWR)

    if len(sys.argv) > 6 and sys.argv[6] == "--mainos-only":
        copy(fd, mainos, 0, MAIN_START, MAIN_SIZE, "MainOS телефона")
        os.fsync(fd)
        os.close(fd)
        print("ГОТОВО: запись завершена")
        subprocess.run(["diskutil", "mountDisk", f"/dev/{disk}"])
        return

    copy(fd, disk_img, IOT_DATA, IOT_DATA, IOT_DATA_SIZE, "IoT Data: исходный раздел")
    copy(fd, mainos, 0, MAIN_START, MAIN_SIZE, "MainOS телефона")

    print("Data телефона")
    ffu = ffu_extract.Ffu(ffu_path)
    size = ffu.block_size
    for block in sorted(ffu.blocks):
        offset = block * size
        if FFU_DATA <= offset < FFU_DATA + FFU_DATA_SIZE:
            os.pwrite(fd, ffu.read(offset, size), DATA_START + offset - FFU_DATA)

    # Таблицы пишем последними: если запись прервётся, старая разметка останется.
    with open(disk_img, "rb") as src:
        mbr = bytearray(src.read(SECTOR))
        src.seek(EXT)
        first_ebr = src.read(SECTOR)
    mbr[446 + 3 * 16:462 + 3 * 16] = entry(TYPE_EXT, EXT, EXT_SIZE)
    iot_ebr = EXT + MIB + 64 * 1024
    write_at(fd, EXT, first_ebr)
    write_at(fd, iot_ebr, ebr(entry(TYPE_NTFS, IOT_DATA - iot_ebr, IOT_DATA_SIZE),
                              entry(TYPE_EXT, MAIN_EBR - EXT, MAIN_START + MAIN_SIZE - MAIN_EBR)))
    write_at(fd, MAIN_EBR, ebr(entry(TYPE_NTFS, MAIN_START - MAIN_EBR, MAIN_SIZE),
                               entry(TYPE_EXT, DATA_EBR - EXT, DATA_START + DATA_SIZE - DATA_EBR)))
    write_at(fd, DATA_EBR, ebr(entry(TYPE_NTFS, DATA_START - DATA_EBR, DATA_SIZE)))
    write_at(fd, 0, bytes(mbr))
    os.fsync(fd)
    os.close(fd)
    print("ГОТОВО: запись завершена")
    subprocess.run(["diskutil", "mountDisk", f"/dev/{disk}"])


if __name__ == "__main__":
    main()
