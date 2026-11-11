#!/usr/bin/env python3
"""Добавляет раздел Windows 10 ARM32 в конец цепочки логических разделов и пишет его образ.

    sudo python3 -I write_desktop.py disk4 62534975488 w32.img [--data-only]
Копирует только области образа с данными (пустые места в образе — свободное место NTFS).
"""
import os
import struct
import subprocess
import sys

MIB = 1048576
SECTOR = 512
EXT = 2016 * MIB
PREV_EBR = 5464 * MIB            # EBR раздела Data телефона
PREV_END = (5465 + 5349) * MIB
NEW_EBR, NEW_START, NEW_SIZE = 10814 * MIB, 10815 * MIB, 12288 * MIB
TYPE_NTFS, TYPE_EXT = 0x07, 0x05


def s(value):
    return value // SECTOR


def entry(kind, start, size):
    return bytes(4) + bytes([kind]) + bytes(3) + struct.pack("<II", s(start), s(size))


def read_entry(sector, index):
    raw = sector[446 + 16 * index:462 + 16 * index]
    return raw[4], struct.unpack_from("<II", raw, 8)


def main():
    disk, expected, image = sys.argv[1:4]
    text = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in text or f"({expected} Bytes)" not in text or "Removable" not in text:
        raise SystemExit("Это не карта из Hekate нужного размера")
    if os.path.getsize(image) != NEW_SIZE:
        raise SystemExit("Неверный размер образа")
    if NEW_START + NEW_SIZE > int(expected):
        raise SystemExit("Раздел не помещается на карту")
    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    fd = os.open(f"/dev/r{disk}", os.O_RDWR)

    mbr = bytearray(os.pread(fd, SECTOR, 0))
    prev = bytearray(os.pread(fd, SECTOR, PREV_EBR))
    if not (len(sys.argv) > 4 and sys.argv[4] == "--data-only"):
        kind, (start, size) = read_entry(mbr, 3)
        if kind != TYPE_EXT or start * SECTOR != EXT:
            raise SystemExit("Неожиданная таблица разделов: расширенный раздел не на месте")
        kind, (start, size) = read_entry(prev, 0)
        if prev[510:512] != b"\x55\xaa" or kind != TYPE_NTFS or (PREV_EBR + start * SECTOR + size * SECTOR) != PREV_END:
            raise SystemExit("Неожиданная таблица разделов: раздел Data телефона не на месте")
    else:
        desktop = os.pread(fd, SECTOR, 0)
        kinds = [read_entry(desktop, i) for i in range(4)]
        if not any(k == TYPE_NTFS and a * SECTOR == NEW_START and b * SECTOR == NEW_SIZE for k, (a, b) in kinds):
            if read_entry(os.pread(fd, SECTOR, NEW_EBR), 0) != (TYPE_NTFS, (s(NEW_START - NEW_EBR), s(NEW_SIZE))):
                raise SystemExit("На карте нет раздела Windows 10 по ожидаемому адресу")

    print("Windows 10 ARM32: запись данных")
    with open(image, "rb") as src:
        src_fd = src.fileno()
        offset, written = 0, 0
        while offset < NEW_SIZE:
            try:
                data = os.lseek(src_fd, offset, os.SEEK_DATA)
            except OSError:
                break
            hole = os.lseek(src_fd, data, os.SEEK_HOLE)
            data -= data % MIB
            hole = min(NEW_SIZE, hole + (-hole) % MIB)
            pos = data
            while pos < hole:
                block = os.pread(src_fd, min(MIB, hole - pos), pos)
                os.pwrite(fd, block, NEW_START + pos)
                pos += len(block)
                written += len(block)
            offset = hole
    print(f"записано {written // MIB} МиБ")
    if len(sys.argv) > 4 and sys.argv[4] == "--data-only":
        os.fsync(fd)
        os.close(fd)
        print("ГОТОВО: запись завершена")
        subprocess.run(["diskutil", "mountDisk", f"/dev/{disk}"])
        return

    # Таблицы в самом конце: при обрыве старая разметка останется.
    new_ebr = bytearray(SECTOR)
    new_ebr[446:462] = entry(TYPE_NTFS, NEW_START - NEW_EBR, NEW_SIZE)
    new_ebr[510:512] = b"\x55\xaa"
    os.pwrite(fd, bytes(new_ebr), NEW_EBR)
    prev[462:478] = entry(TYPE_EXT, NEW_EBR - EXT, NEW_START + NEW_SIZE - NEW_EBR)
    os.pwrite(fd, bytes(prev), PREV_EBR)
    mbr[446 + 48:462 + 48] = entry(TYPE_EXT, EXT, NEW_START + NEW_SIZE - EXT)
    os.pwrite(fd, bytes(mbr), 0)
    os.fsync(fd)
    os.close(fd)
    print("ГОТОВО: запись завершена")
    subprocess.run(["diskutil", "mountDisk", f"/dev/{disk}"])


if __name__ == "__main__":
    main()
