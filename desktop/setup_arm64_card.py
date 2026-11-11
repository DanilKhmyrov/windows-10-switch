#!/usr/bin/env python3
"""Installs Windows 10 ARM64 next to ARM32 on the card:
1) MBR backup -> mbr-backup.bin in the image folder;
2) fourth primary MBR partition = ARM64 NTFS (23104 MiB, 24 GiB). It used to point to an
   extended partition with old IoT partitions; their data on the card is not touched;
3) writes the partition image (data regions only) and verifies by reading back;
4) wp64/bl33.bin = 64-bit loader, menu entry wp64 -> "Windows 10 ARM64" with an icon.

    sudo python3 -I setup_arm64_card.py disk4 62534975488 w64.img bl33-64.bin icon.bmp
"""
import filecmp
import os
import shutil
import struct
import subprocess
import sys
import tempfile

MIB = 1048576
SECTOR = 512
START, SIZE = 23104 * MIB, 24576 * MIB
P2_END = (10815 + 12288) * MIB
TITLE = "Windows 10 ARM64"


def entry(kind, start, size):
    return bytes(4) + bytes([kind]) + bytes(3) + struct.pack("<II", start // SECTOR, size // SECTOR)


def read_entry(mbr, i):
    raw = mbr[446 + 16 * i:462 + 16 * i]
    first, count = struct.unpack_from("<II", raw, 8)
    return raw[4], first * SECTOR, count * SECTOR


def main():
    disk, expected, image, bl33, icon = sys.argv[1:6]
    info = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in info or f"({expected} Bytes)" not in info or "Removable" not in info:
        raise SystemExit("Not a Hekate SD card of the expected size")
    if os.path.getsize(image) != SIZE:
        raise SystemExit("Wrong image size")
    if START + SIZE > int(expected):
        raise SystemExit("The partition does not fit on the card")

    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    fd = os.open(f"/dev/r{disk}", os.O_RDWR)
    mbr = bytearray(os.pread(fd, SECTOR, 0))
    if mbr[510:512] != b"\x55\xaa":
        raise SystemExit("No MBR signature")
    parts = [read_entry(mbr, i) for i in range(4)]
    print("MBR now:", [(hex(k), s // MIB, n // MIB) for k, s, n in parts])
    for i, (kind, start, size) in enumerate(parts[:3]):
        if kind and start < START + SIZE and start + size > START:
            raise SystemExit(f"Partition {i + 1} overlaps the ARM64 area")
    if parts[1][1] + parts[1][2] > START:
        raise SystemExit("The ARM32 partition extends into the ARM64 area")
    backup = os.path.join(os.path.dirname(os.path.abspath(image)), "mbr-backup.bin")
    if not os.path.exists(backup):
        open(backup, "wb").write(bytes(mbr))
        print("MBR backup:", backup)

    # 3) partition data
    written = 0
    with open(image, "rb") as src:
        sfd = src.fileno()
        offset = 0
        while offset < SIZE:
            try:
                data = os.lseek(sfd, offset, os.SEEK_DATA)
            except OSError:
                break
            hole = os.lseek(sfd, data, os.SEEK_HOLE)
            data -= data % MIB
            hole = min(SIZE, hole + (-hole) % MIB)
            pos = data
            while pos < hole:
                block = os.pread(sfd, min(MIB, hole - pos), pos)
                os.pwrite(fd, block, START + pos)
                if os.pread(fd, len(block), START + pos) != block:
                    raise SystemExit(f"ERROR: mismatch after writing at {pos // MIB} MiB")
                pos += len(block)
                written += len(block)
                if written % (512 * MIB) == 0:
                    print(f"  written {written // MIB} MiB", flush=True)
            offset = hole
    print(f"written {written // MIB} MiB")

    # 2) partition table last: if interrupted, the old layout stays.
    mbr[446 + 48:462 + 48] = entry(0x07, START, SIZE)
    os.pwrite(fd, bytes(mbr), 0)
    os.fsync(fd)
    os.close(fd)

    # 4) loader and menu entry
    mnt = tempfile.mkdtemp(prefix="switch-esp.", dir="/tmp")
    subprocess.run(["mount", "-t", "msdos", f"/dev/{disk}s1", mnt], check=True)
    try:
        wp, wp64 = os.path.join(mnt, "wp"), os.path.join(mnt, "wp64")
        os.makedirs(wp64, exist_ok=True)
        if not os.path.exists(os.path.join(wp64, "bl31.bin")):
            shutil.copyfile(os.path.join(wp, "bl31.bin"), os.path.join(wp64, "bl31.bin"))
        if os.path.exists(os.path.join(wp64, "bl33.bin")):
            shutil.copyfile(os.path.join(wp64, "bl33.bin"), os.path.join(wp64, "bl33-prev.bin"))
        shutil.copyfile(bl33, os.path.join(wp64, "bl33.bin"))
        if not filecmp.cmp(bl33, os.path.join(wp64, "bl33.bin"), shallow=False):
            raise SystemExit("ERROR: wp64/bl33.bin does not match")
        ini = os.path.join(mnt, "bootloader", "ini", "wp64.ini")
        text = open(ini, encoding="utf-8", errors="surrogateescape").read()
        nl = "\r\n" if "\r\n" in text else "\n"
        lines = text.split(nl)
        first = next(i for i, l in enumerate(lines) if l.startswith("["))
        lines[first] = f"[{TITLE}]"
        open(ini, "w", encoding="utf-8", errors="surrogateescape", newline="").write(nl.join(lines))
        shutil.copyfile(icon, os.path.join(mnt, "bootloader", "res", TITLE + ".bmp"))
        print(open(ini, encoding="utf-8", errors="replace").read())
        print("wp64:", sorted(os.listdir(wp64)))
    finally:
        subprocess.run(["sync"])
        subprocess.run(["umount", mnt])
        os.rmdir(mnt)
    print("DONE: Windows 10 ARM64 is on the card")
    subprocess.run(["diskutil", "mountDisk", f"/dev/{disk}"])


if __name__ == "__main__":
    main()
