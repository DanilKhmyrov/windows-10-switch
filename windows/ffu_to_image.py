#!/usr/bin/env python3
"""Разворачивает FFU с разметкой MBR в обычный образ диска.

    python3 ffu_to_image.py flash.ffu disk.img

Незаписанные блоки становятся нулями: образ можно целиком записать на карту.
"""
import argparse
import struct
import sys

from ffu_extract import Ffu

SECTOR = 512


def image_end(boot_sector):
    """Конец последнего основного раздела в байтах."""
    end = 0
    for index in range(4):
        entry = boot_sector[446 + 16 * index:462 + 16 * index]
        first, sectors = struct.unpack_from("<II", entry, 8)
        if entry[4]:
            end = max(end, (first + sectors) * SECTOR)
    if not end:
        raise SystemExit("В образе нет разделов MBR")
    return end


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ffu")
    parser.add_argument("output")
    args = parser.parse_args()

    ffu = Ffu(args.ffu)
    boot_sector = ffu.read(0, SECTOR)
    if boot_sector[510:512] != b"\x55\xaa":
        raise SystemExit("В образе нет загрузочной записи MBR")

    end = image_end(boot_sector)
    with open(args.output, "wb") as output:
        output.truncate(end)
        for block in sorted(ffu.blocks):
            offset = block * ffu.block_size
            if offset < end:
                output.seek(offset)
                output.write(ffu.read(offset, ffu.block_size))
    print(f"{args.output}: {end} байт")


if __name__ == "__main__":
    sys.exit(main())
