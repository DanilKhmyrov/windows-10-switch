#!/usr/bin/env python3
"""Prepares a microSD card for Windows 10 ARM64 on the Switch (macOS).

    sudo python3 -I setup_card.py partition DISK SIZE_BYTES [--hekate-gib 4] [--windows-gib 24]
        ERASES THE WHOLE CARD and creates an MBR layout:
          1. FAT32 "SWITCH"   Hekate, loaders (copy Hekate back onto it afterwards)
          2. FAT32 "WINBOOT"  512 MiB: Windows Boot Manager, BCD, \\agent
          3. NTFS             Windows 10 ARM64
        Prints the disk signature and partition offsets for build_w64.sh.

    sudo python3 -I setup_card.py install DISK SIZE_BYTES BUILD_FOLDER
        Writes BUILD_FOLDER/w64.img to partition 3 (data regions only, verified by reading back)
        and copies BUILD_FOLDER/boot/ to partition 2. Checks first that the image was built for
        this card (BUILD_FOLDER/card.txt from build_w64.sh).

DISK is the card as shown by `diskutil list` (e.g. disk4) while Hekate exposes it over USB
(Tools > USB Tools > SD Card). SIZE_BYTES is its exact size from `diskutil info`, as a guard
against picking the wrong disk.
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys

MIB = 1048576
SECTOR = 512
BOOT_MIB = 512


def diskutil(*args, capture=True):
    return subprocess.run(["diskutil", *args], check=True, capture_output=capture, text=True).stdout


def check_card(disk, expected, allow_image=False):
    info = diskutil("info", disk)
    is_image = "Disk Image" in info
    if f"({expected} Bytes)" not in info:
        raise SystemExit(f"{disk} is not {expected} bytes. Check `diskutil info {disk}`.")
    if "Internal:                  Yes" in info and not is_image:
        raise SystemExit(f"{disk} is an internal disk. Refusing.")
    if "SD RAW" not in info and not (allow_image and is_image):
        raise SystemExit(f"{disk} is not a card exposed by Hekate (media name 'SD RAW').")


def read_mbr(disk):
    fd = os.open(f"/dev/r{disk}", os.O_RDONLY)
    try:
        mbr = os.pread(fd, SECTOR, 0)
    finally:
        os.close(fd)
    if mbr[510:512] != b"\x55\xaa":
        raise SystemExit("No MBR on the card")
    parts = []
    for i in range(4):
        raw = mbr[446 + 16 * i:462 + 16 * i]
        first, count = struct.unpack_from("<II", raw, 8)
        parts.append((raw[4], first * SECTOR, count * SECTOR))
    return mbr, struct.unpack_from("<I", mbr, 440)[0], parts


def partition(args):
    check_card(args.disk, args.size, args.allow_image)
    total_mib = args.size // MIB
    need_mib = 16 + args.hekate_gib * 1024 + BOOT_MIB + args.windows_gib * 1024 + 16
    if need_mib > total_mib:
        raise SystemExit(f"Needs {need_mib} MiB, the card has {total_mib} MiB. Use smaller sizes.")
    print(diskutil("list", args.disk))
    print(f"ALL DATA ON {args.disk} WILL BE ERASED (Hekate files, emuMMC, Linux, Android, everything).")
    answer = input(f"Type ERASE {args.disk} to continue: ")
    if answer.strip() != f"ERASE {args.disk}":
        raise SystemExit("Cancelled, nothing changed.")
    # The NTFS partition is created as FAT32 first and retyped below; diskutil cannot make NTFS.
    sectors = lambda mib: f"{mib * MIB // SECTOR}S"
    print(diskutil("partitionDisk", args.disk, "4", "MBR",
                   "FAT32", "SWITCH", sectors(args.hekate_gib * 1024),
                   "FAT32", "WINBOOT", sectors(BOOT_MIB),
                   "FAT32", "WINDOWS", sectors(args.windows_gib * 1024),
                   "Free Space", "FREE", "R"))
    diskutil("unmountDisk", f"/dev/{args.disk}")
    mbr, signature, parts = read_mbr(args.disk)
    kind, start, size = parts[2]
    if kind == 0 or size != args.windows_gib * 1024 * MIB or any(
            k and (st % MIB or sz % MIB) for k, st, sz in parts[:3]):
        raise SystemExit(f"Unexpected layout from diskutil: {parts}")
    mbr = bytearray(mbr)
    mbr[446 + 32 + 4] = 0x07                  # partition 3: NTFS
    # diskutil leaves the disk signature at 0; Windows would then write its own and the BCD
    # (which refers to the disk by signature) would no longer match.
    if struct.unpack_from("<I", mbr, 440)[0] == 0:
        signature = 0
        while signature == 0:
            signature = struct.unpack("<I", os.urandom(4))[0]
        struct.pack_into("<I", mbr, 440, signature)
    fd = os.open(f"/dev/r{args.disk}", os.O_RDWR)
    try:
        for off in range(0, 64 * MIB, MIB):   # drop the temporary FAT boot sector and tables
            os.pwrite(fd, bytes(MIB), start + off)
        os.pwrite(fd, bytes(mbr), 0)
        os.fsync(fd)
    finally:
        os.close(fd)
    diskutil("mountDisk", f"/dev/{args.disk}")
    print_layout(args.disk)


def print_layout(disk):
    _, signature, parts = read_mbr(disk)
    for i, (kind, start, size) in enumerate(parts, 1):
        if kind:
            print(f"  partition {i}: type {kind:#04x}, start {start // MIB} MiB, size {size // MIB} MiB")
    _, boot_start, _ = parts[1]
    _, win_start, win_size = parts[2]
    print("\nParameters for build_w64.sh (DISK_SIGNATURE WINDOWS_START_MiB BOOT_START_MiB SIZE_MiB):")
    print(f"  {signature:#010x} {win_start // MIB} {boot_start // MIB} {win_size // MIB}")


def install(args):
    check_card(args.disk, args.size, args.allow_image)
    image = os.path.join(args.build, "w64.img")
    boot = os.path.join(args.build, "boot")
    card_txt = os.path.join(args.build, "card.txt")
    built = open(card_txt).read().split()
    signature, win_mib, boot_mib, size_mib = int(built[0], 0), int(built[1]), int(built[2]), int(built[3])
    diskutil("unmountDisk", f"/dev/{args.disk}")
    _, card_signature, parts = read_mbr(args.disk)
    kind, start, size = parts[2]
    _, boot_start, _ = parts[1]
    if (card_signature, start // MIB, boot_start // MIB) != (signature, win_mib, boot_mib):
        raise SystemExit(f"The image was built for signature {signature:#010x}, Windows at {win_mib} MiB, "
                         f"boot at {boot_mib} MiB; this card has {card_signature:#010x}, "
                         f"{start // MIB} MiB, {boot_start // MIB} MiB. Rebuild with the values "
                         f"printed by `setup_card.py partition`.")
    if kind != 0x07 or os.path.getsize(image) != size_mib * MIB or size_mib * MIB > size:
        raise SystemExit("Partition 3 is not NTFS or the image does not fit it")

    fd = os.open(f"/dev/r{args.disk}", os.O_RDWR)
    written = 0
    try:
        with open(image, "rb") as src:
            sfd = src.fileno()
            total = os.path.getsize(image)
            offset = 0
            while offset < total:
                try:
                    data = os.lseek(sfd, offset, os.SEEK_DATA)
                except OSError:
                    break
                hole = os.lseek(sfd, data, os.SEEK_HOLE)
                data -= data % MIB
                hole = min(total, hole + (-hole) % MIB)
                pos = data
                while pos < hole:
                    block = os.pread(sfd, min(MIB, hole - pos), pos)
                    os.pwrite(fd, block, start + pos)
                    if os.pread(fd, len(block), start + pos) != block:
                        raise SystemExit(f"ERROR: mismatch after writing at {pos // MIB} MiB")
                    pos += len(block)
                    written += len(block)
                    if written % (512 * MIB) == 0:
                        print(f"  written {written // MIB} MiB", flush=True)
                offset = hole
        os.fsync(fd)
    finally:
        os.close(fd)
    print(f"Windows partition: written {written // MIB} MiB")

    diskutil("mount", f"{args.disk}s2")
    mnt = next(line.split(":", 1)[1].strip() for line in diskutil("info", f"{args.disk}s2").splitlines()
               if line.strip().startswith("Mount Point:"))
    try:
        for name in os.listdir(boot):
            src, dst = os.path.join(boot, name), os.path.join(mnt, name)
            if os.path.isdir(src):
                shutil.copytree(src, dst, dirs_exist_ok=True)
            else:
                shutil.copyfile(src, dst)
        bcd = os.path.join(mnt, "EFI", "Microsoft", "Boot", "BCD")
        if open(bcd, "rb").read() != open(os.path.join(boot, "EFI", "Microsoft", "Boot", "BCD"), "rb").read():
            raise SystemExit("ERROR: BCD on the card does not match")
    finally:
        subprocess.run(["sync"])
    print("DONE: boot partition and Windows partition are written")
    diskutil("mountDisk", f"/dev/{args.disk}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("partition")
    p.add_argument("disk")
    p.add_argument("size", type=int)
    p.add_argument("--hekate-gib", type=int, default=4)
    p.add_argument("--windows-gib", type=int, default=24)
    p.add_argument("--allow-image", action="store_true", help=argparse.SUPPRESS)
    i = sub.add_parser("install")
    i.add_argument("disk")
    i.add_argument("size", type=int)
    i.add_argument("build")
    i.add_argument("--allow-image", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if os.geteuid() != 0 and not args.allow_image:
        raise SystemExit("Run with sudo: raw access to the card needs root.")
    partition(args) if args.command == "partition" else install(args)


if __name__ == "__main__":
    main()
