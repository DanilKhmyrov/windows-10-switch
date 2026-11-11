#!/usr/bin/env python3
"""Replaces the contents of a file stored on a partition as one contiguous extent, without touching
the file system: first checks that exactly the OLD file is at that address on the card,
then writes the NEW one (same size) and verifies the write by reading it back.

    sudo python3 -I replace_extent.py disk4 62534975488 PARTITION_START_MiB BYTE_OFFSET old new
"""
import os
import subprocess
import sys

MIB = 1048576


def main():
    disk, expected, part_mib, offset, old_path, new_path = sys.argv[1:7]
    text = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in text or f"({expected} Bytes)" not in text:
        raise SystemExit("Wrong card")
    old = open(old_path, "rb").read()
    new = open(new_path, "rb").read()
    if len(old) != len(new) or len(new) % 4096:
        raise SystemExit("Sizes do not match")
    pos = int(part_mib) * MIB + int(offset, 0)
    if pos % 4096 or pos + len(new) > int(expected):
        raise SystemExit("Bad address")
    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    fd = os.open(f"/dev/r{disk}", os.O_RDWR)
    try:
        if os.pread(fd, len(old), pos) != old:
            raise SystemExit("The card does not hold the expected file at this address. Nothing written.")
        os.pwrite(fd, new, pos)
        os.fsync(fd)
        if os.pread(fd, len(new), pos) != new:
            raise SystemExit("ERROR: data does not match after writing")
    finally:
        os.close(fd)
    print(f"DONE: wrote {len(new)} bytes at {pos:#x}")


if __name__ == "__main__":
    main()
