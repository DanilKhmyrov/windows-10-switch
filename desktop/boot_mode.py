#!/usr/bin/env python3
"""Переключает, какая система стоит вторым основным разделом MBR. Данные не трогает.

    sudo python3 -I boot_mode.py disk4 62534975488 desktop   # Windows 10 ARM32
    sudo python3 -I boot_mode.py disk4 62534975488 iot       # IoT Core, как было
Меняет только MBR и одну запись EBR (ссылку на раздел Windows 10).
"""
import os
import struct
import subprocess
import sys

MIB = 1048576
SECTOR = 512
EXT = 2016 * MIB
IOT_MAINOS = (72 * MIB, 1344 * MIB)
DESKTOP = (10815 * MIB, 12288 * MIB)
DESKTOP_EBR = 10814 * MIB
PHONE_DATA_EBR = 5464 * MIB
TYPE_NTFS, TYPE_EXT, TYPE_FAT32, TYPE_EFI = 0x07, 0x05, 0x0C, 0xEF
ESP = (2 * MIB, 64 * MIB)


def s(value):
    return value // SECTOR


def entry(kind, start, size):
    return bytes(4) + bytes([kind]) + bytes(3) + struct.pack("<II", s(start), s(size))


def parse(sector, index):
    raw = sector[446 + 16 * index:462 + 16 * index]
    start, size = struct.unpack_from("<II", raw, 8)
    return raw[4], start * SECTOR, size * SECTOR


def main():
    disk, expected, mode = sys.argv[1:4]
    if mode not in ("desktop", "iot"):
        raise SystemExit("Режим: desktop или iot")
    text = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in text or f"({expected} Bytes)" not in text or "Removable" not in text:
        raise SystemExit("Это не карта из Hekate нужного размера")
    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    fd = os.open(f"/dev/r{disk}", os.O_RDWR)
    mbr = bytearray(os.pread(fd, SECTOR, 0))
    link = bytearray(os.pread(fd, SECTOR, PHONE_DATA_EBR))
    desktop_ebr = os.pread(fd, SECTOR, DESKTOP_EBR)

    if parse(mbr, 3)[:2] != (TYPE_EXT, EXT):
        raise SystemExit("Неожиданный MBR: расширенный раздел не на месте")
    if parse(desktop_ebr, 0) != (TYPE_NTFS, DESKTOP[0] - DESKTOP_EBR, DESKTOP[1]):
        raise SystemExit("Неожиданная разметка: раздел Windows 10 не на месте")
    if parse(mbr, 1)[1:] not in (IOT_MAINOS, DESKTOP):
        raise SystemExit("Неожиданный MBR: второй раздел не IoT и не Windows 10")

    # UEFI отбрасывает всю таблицу, если основной раздел лежит внутри расширенного,
    # поэтому в режиме desktop расширенный раздел заканчивается перед Windows 10.
    if parse(mbr, 0)[1:] != ESP:
        raise SystemExit("Неожиданный MBR: первый раздел не EFIESP")
    if mode == "desktop":
        mbr[446:462] = entry(TYPE_EFI, *ESP)   # установка Windows ищет раздел EFI по типу
        mbr[462:478] = entry(TYPE_NTFS, *DESKTOP)
        mbr[494:510] = entry(TYPE_EXT, EXT, DESKTOP_EBR - EXT)
        link[462:478] = bytes(16)            # раздел больше не числится логическим
    else:
        mbr[446:462] = entry(TYPE_FAT32, *ESP)
        mbr[462:478] = entry(TYPE_NTFS, *IOT_MAINOS)
        mbr[494:510] = entry(TYPE_EXT, EXT, DESKTOP[0] + DESKTOP[1] - EXT)
        link[462:478] = entry(TYPE_EXT, DESKTOP_EBR - EXT, DESKTOP[0] + DESKTOP[1] - DESKTOP_EBR)
    os.pwrite(fd, bytes(link), PHONE_DATA_EBR)
    os.pwrite(fd, bytes(mbr), 0)
    os.fsync(fd)
    os.close(fd)
    print(f"ГОТОВО: режим {mode}")
    subprocess.run(["diskutil", "mountDisk", f"/dev/{disk}"])


if __name__ == "__main__":
    main()
