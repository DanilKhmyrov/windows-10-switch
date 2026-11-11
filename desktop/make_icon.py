#!/usr/bin/env python3
"""Draws the Hekate menu icon: a window of four light-blue tiles on a dark background.
Format accepted by Nyx: BMP 192x192, 32 bits per pixel (BGRA), rows stored bottom-up.

    python3 make_icon.py icon_windows.bmp
"""
import struct
import sys

SIZE = 192
BG = (0x2A, 0x1F, 0x1B, 0xFF)      # B, G, R, A: dark blue background
TILE = (0xEF, 0xA4, 0x00, 0xFF)    # light blue #00A4EF
MARGIN, GAP = 40, 6


def pixel(x, y):
    inner = SIZE - 2 * MARGIN
    tile = (inner - GAP) // 2
    for tx in (MARGIN, MARGIN + tile + GAP):
        for ty in (MARGIN, MARGIN + tile + GAP):
            if tx <= x < tx + tile and ty <= y < ty + tile:
                return TILE
    return BG


rows = []
for y in range(SIZE - 1, -1, -1):          # BMP stores rows bottom-up
    rows.append(b"".join(bytes(pixel(x, y)) for x in range(SIZE)))
data = b"".join(rows)
header_size = 14 + 40
bmp = b"BM" + struct.pack("<IHHI", header_size + len(data), 0, 0, header_size)
bmp += struct.pack("<IiiHHIIiiII", 40, SIZE, SIZE, 1, 32, 0, len(data), 2835, 2835, 0, 0)
open(sys.argv[1], "wb").write(bmp + data)
print(sys.argv[1], len(bmp + data), "bytes")
