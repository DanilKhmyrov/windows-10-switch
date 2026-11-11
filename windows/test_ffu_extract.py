#!/usr/bin/env python3
"""Собирает маленький искусственный FFU и проверяет распаковщик."""
import struct
import tempfile
from pathlib import Path

import ffu_extract

CHUNK = 64 * 1024
BLOCK = 4096
SECTOR = 512


def pad(data):
    return data + bytes((CHUNK - len(data) % CHUNK) % CHUNK)


def make_disk(partition):
    first_lba = 2048
    entry = bytes(16) + bytes(16)
    entry += struct.pack("<QQ", first_lba, first_lba + len(partition) // SECTOR - 1)
    entry += bytes(8) + "EFIESP".encode("utf-16-le").ljust(72, b"\0")
    header = b"EFI PART" + bytes(64) + struct.pack("<QII", 2, 1, 128)
    disk = bytearray(first_lba * SECTOR + len(partition))
    disk[SECTOR:SECTOR + len(header)] = header
    disk[2 * SECTOR:2 * SECTOR + len(entry)] = entry
    disk[first_lba * SECTOR:] = partition
    return bytes(disk)


def make_ffu(disk):
    security = struct.pack("<I12sIIII", 32, b"SignedImage ", CHUNK // 1024, 0, 7, 9)
    security = pad(security + bytes(16))
    manifest = b"manifest"
    image = pad(struct.pack("<I12sII", 24, b"ImageFlash  ", len(manifest), 0) + manifest)

    blocks = [disk[i:i + BLOCK] for i in range(0, len(disk), BLOCK)]
    used = [i for i, block in enumerate(blocks) if any(block)]
    table = b"".join(struct.pack("<IIII", 1, 1, 0, i) for i in used)
    store = struct.pack("<IHHHH", 0, 1, 0, 2, 0) + bytes(192)
    store += struct.pack("<IIIII", BLOCK, len(used), len(table), 0, 0)
    store = store.ljust(ffu_extract.STORE_HEADER_SIZE, b"\0")
    store = pad(store + table)
    return security + image + store + b"".join(blocks[i] for i in used)


def main():
    partition = bytes((i * 3) & 0xFF for i in range(BLOCK * 3))
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "flash.ffu"
        path.write_bytes(make_ffu(make_disk(partition)))
        ffu = ffu_extract.Ffu(path)
        start, size = ffu_extract.find_partition(ffu, "EFIESP")
        assert (start, size) == (2048 * SECTOR, len(partition)), (start, size)
        assert ffu.read(start, size) == partition, "содержимое раздела не совпало"
    print("ok: разметка и содержимое раздела совпали")


if __name__ == "__main__":
    main()
