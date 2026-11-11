#!/usr/bin/env python3
"""Достаёт один раздел из образа Windows в формате FFU (версия 1).

    python3 ffu_extract.py flash.ffu EFIESP efiesp.img

FFU — это снимок диска: только занятые блоки и таблица, куда их записать.
"""
import argparse
import struct
import sys

SECURITY_SIGNATURE = b"SignedImage "
IMAGE_SIGNATURE = b"ImageFlash  "
GPT_SIGNATURE = b"EFI PART"
ACCESS_FROM_BEGIN = 0
STORE_HEADER_SIZE = 248


def next_chunk(offset, chunk):
    return offset + (chunk - offset % chunk) % chunk


class Ffu:
    def __init__(self, path):
        self.file = open(path, "rb")
        self.blocks = {}
        self._parse()

    def _at(self, offset, size):
        self.file.seek(offset)
        data = self.file.read(size)
        if len(data) != size:
            raise SystemExit("Файл FFU обрывается раньше времени")
        return data

    def _parse(self):
        size, signature, chunk_kb, _, catalog, hash_table = struct.unpack(
            "<I12sIIII", self._at(0, 32)
        )
        if signature != SECURITY_SIGNATURE:
            raise SystemExit("Это не FFU: нет подписи SignedImage")
        chunk = chunk_kb * 1024
        offset = next_chunk(size + catalog + hash_table, chunk)

        size, signature, manifest, _ = struct.unpack("<I12sII", self._at(offset, 24))
        if signature != IMAGE_SIGNATURE:
            raise SystemExit("Неверный заголовок образа FFU")
        offset = next_chunk(offset + size + manifest, chunk)

        store = self._at(offset, STORE_HEADER_SIZE)
        major = struct.unpack_from("<H", store, 4)[0]
        if major != 1:
            raise SystemExit(f"Поддержан только FFU версии 1, а здесь {major}")
        self.block_size, write_count, write_len, _, validate_len = struct.unpack_from(
            "<IIIII", store, 12 + 192
        )
        descriptors = offset + STORE_HEADER_SIZE + validate_len
        payload = next_chunk(descriptors + write_len, chunk)
        table = self._at(descriptors, write_len)

        position = 0
        block_offset = payload
        for _ in range(write_count):
            locations, count = struct.unpack_from("<II", table, position)
            position += 8
            target = None
            for _ in range(locations):
                method, index = struct.unpack_from("<II", table, position)
                position += 8
                if method == ACCESS_FROM_BEGIN and target is None:
                    target = index
            for step in range(count):
                if target is not None:
                    self.blocks[target + step] = block_offset
                block_offset += self.block_size

    def read(self, offset, size):
        """Читает диск как обычный файл. Незаписанные блоки — нули."""
        result = bytearray()
        while size:
            block, inner = divmod(offset, self.block_size)
            part = min(size, self.block_size - inner)
            if block in self.blocks:
                result += self._at(self.blocks[block] + inner, part)
            else:
                result += bytes(part)
            offset += part
            size -= part
        return bytes(result)


def find_partition(ffu, name):
    for sector in (512, 4096):
        header = ffu.read(sector, 92)
        if header[:8] != GPT_SIGNATURE:
            continue
        table_lba, count, entry_size = struct.unpack_from("<QII", header, 72)
        table = ffu.read(table_lba * sector, count * entry_size)
        for index in range(count):
            entry = table[index * entry_size:(index + 1) * entry_size]
            first, last = struct.unpack_from("<QQ", entry, 32)
            label = entry[56:128].decode("utf-16-le").split("\0")[0]
            if label.lower() == name.lower():
                return first * sector, (last - first + 1) * sector
    # Образы для Raspberry Pi размечены по-старому (MBR), и имён разделов там нет.
    # EFIESP в них — первый раздел с файловой системой FAT.
    boot = ffu.read(0, 512)
    if name.lower() == "efiesp" and boot[510:512] == b"\x55\xaa":
        for index in range(4):
            entry = boot[446 + 16 * index:462 + 16 * index]
            if entry[4] in (0x04, 0x06, 0x0B, 0x0C, 0x0E):
                first, sectors = struct.unpack_from("<II", entry, 8)
                return first * 512, sectors * 512
    raise SystemExit(f"Раздел {name} не найден")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ffu")
    parser.add_argument("partition")
    parser.add_argument("output")
    args = parser.parse_args()

    ffu = Ffu(args.ffu)
    start, size = find_partition(ffu, args.partition)
    with open(args.output, "wb") as output:
        output.write(ffu.read(start, size))
    print(f"{args.partition}: {size} байт записано в {args.output}")


if __name__ == "__main__":
    sys.exit(main())
