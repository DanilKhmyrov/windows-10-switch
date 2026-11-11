#!/usr/bin/env python3
"""Adds another Windows ARM64 installation to an existing card (the test console's layout).

    sudo python3 -I add_windows_partition.py partition DISK SIZE_BYTES SLOT START_MiB IMAGE
        Writes IMAGE (an NTFS partition image from build_w64.sh) at START_MiB and points MBR entry
        SLOT (1-4) at it, type NTFS. Refuses if the area overlaps any other partition. The old
        MBR is saved next to the image first, and the table is written last, so an interrupted
        run leaves the old layout in place. Whatever was stored in that area is overwritten.

    sudo python3 -I add_windows_partition.py settype DISK SIZE_BYTES SLOT TYPE BACKUP_FILE
        Changes only the MBR type byte of partition SLOT (for example 0x0C: Windows creates no
        volume for a 0xEF partition on an MBR disk, so setup cannot find its boot partition).

    sudo python3 -I add_windows_partition.py hekate DISK SIZE_BYTES BUILD_BOOT_FOLDER BL33 NAME FOLDER ICON BACKUP
        On the Hekate FAT partition (partition 1): puts the boot manager and BCD from
        BUILD_BOOT_FOLDER/EFI/Microsoft/Boot into EFI/Microsoft/Boot with the marker file
        win11.tag (the WIN11=1 UEFI boots the partition that has it), creates FOLDER/ with
        bl31.bin (copied from wp64/) and BL33, and the menu entry NAME with ICON.
        Files of the old ARM32 entry (wp/, wp.ini, its icon, EFI/Boot/bootarm.efi, the ARM32 boot
        manager) are first copied to the BACKUP folder on the Mac and checked, then removed from
        the card to make room (partition 1 is only 64 MiB on the test card).
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


def check_card(disk, expected):
    info = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in info or f"({expected} Bytes)" not in info:
        raise SystemExit("Not the Hekate SD card of the expected size")


def read_parts(mbr):
    parts = []
    for i in range(4):
        raw = mbr[446 + 16 * i:462 + 16 * i]
        first, count = struct.unpack_from("<II", raw, 8)
        parts.append((raw[4], first * SECTOR, count * SECTOR))
    return parts


def partition(disk, expected, slot, start_mib, image):
    check_card(disk, expected)
    start, size = start_mib * MIB, os.path.getsize(image)
    if size % MIB or start + size > int(expected):
        raise SystemExit("The image does not fit on the card")
    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    fd = os.open(f"/dev/r{disk}", os.O_RDWR)
    try:
        mbr = bytearray(os.pread(fd, SECTOR, 0))
        if mbr[510:512] != b"\x55\xaa":
            raise SystemExit("No MBR signature")
        parts = read_parts(mbr)
        print("MBR now:", [(hex(k), s // MIB, n // MIB) for k, s, n in parts])
        for i, (kind, pstart, psize) in enumerate(parts, 1):
            if i != slot and kind and pstart < start + size and pstart + psize > start:
                raise SystemExit(f"Partition {i} overlaps {start_mib}..{(start + size) // MIB} MiB")
        backup = os.path.join(os.path.dirname(os.path.abspath(image)), f"mbr-before-slot{slot}.bin")
        open(backup, "wb").write(bytes(mbr))
        print("MBR backup:", backup)
        written = 0
        with open(image, "rb") as src:
            sfd = src.fileno()
            offset = 0
            while offset < size:
                try:
                    data = os.lseek(sfd, offset, os.SEEK_DATA)
                except OSError:
                    break
                hole = os.lseek(sfd, data, os.SEEK_HOLE)
                data -= data % MIB
                hole = min(size, hole + (-hole) % MIB)
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
        print(f"written {written // MIB} MiB")
        entry = bytes(4) + bytes([0x07]) + bytes(3) + struct.pack("<II", start // SECTOR, size // SECTOR)
        mbr[446 + 16 * (slot - 1):462 + 16 * (slot - 1)] = entry
        os.pwrite(fd, bytes(mbr), 0)
        os.fsync(fd)
    finally:
        os.close(fd)
    print(f"DONE: partition {slot} = NTFS at {start_mib} MiB, {size // MIB} MiB")
    subprocess.run(["diskutil", "mountDisk", f"/dev/{disk}"])


def settype(disk, expected, slot, kind, backup):
    """Changes only the type byte of MBR entry SLOT (contents are untouched); saves the MBR first."""
    check_card(disk, expected)
    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    fd = os.open(f"/dev/r{disk}", os.O_RDWR)
    try:
        mbr = bytearray(os.pread(fd, SECTOR, 0))
        if mbr[510:512] != b"\x55\xaa":
            raise SystemExit("No MBR signature")
        old = mbr[446 + 16 * (slot - 1) + 4]
        if not old:
            raise SystemExit(f"Partition {slot} is empty")
        open(backup, "wb").write(bytes(mbr))
        mbr[446 + 16 * (slot - 1) + 4] = kind
        os.pwrite(fd, bytes(mbr), 0)
        os.fsync(fd)
        if os.pread(fd, SECTOR, 0) != bytes(mbr):
            raise SystemExit("ERROR: MBR mismatch after writing")
    finally:
        os.close(fd)
    print(f"DONE: partition {slot} type {old:#04x} -> {kind:#04x} (old MBR saved to {backup})")
    subprocess.run(["diskutil", "mountDisk", f"/dev/{disk}"])


# Boot manager files needed for a small Hekate partition (64 MiB on the test card); the
# remaining language folders and memtest are optional.
BOOT_FILES = ("bootmgfw.efi", "BCD", "boot.stl")
BOOT_DIRS = ("en-US", "ru-RU", "Fonts")


def hekate(disk, expected, boot, bl33, name, folder, icon, backup):
    check_card(disk, expected)
    mnt = tempfile.mkdtemp(prefix="hekate.", dir="/tmp")
    subprocess.run(["mount", "-t", "msdos", f"/dev/{disk}s1", mnt], check=True)
    try:
        # Old ARM32 entry: copied to BACKUP on the Mac, checked, then removed from the card.
        os.makedirs(backup, exist_ok=True)
        for rel in ("wp", "bootloader/ini/wp.ini", "bootloader/res/Windows 10 ARM32.bmp",
                    "EFI/Boot/bootarm.efi", "EFI/Microsoft"):
            path = os.path.join(mnt, rel)
            if not os.path.exists(path):
                continue
            dst = os.path.join(backup, rel.replace("/", "_"))
            if os.path.isdir(path):
                shutil.copytree(path, dst, dirs_exist_ok=True)
                same = not filecmp.dircmp(path, dst).diff_files
                if same:
                    shutil.rmtree(path)
            else:
                shutil.copyfile(path, dst)
                same = filecmp.cmp(path, dst, shallow=False)
                if same:
                    os.remove(path)
            if not same:
                raise SystemExit(f"ERROR: backup of {rel} does not match, left on the card")
            print("backed up to the Mac and removed:", rel)
        src_boot = os.path.join(boot, "EFI", "Microsoft", "Boot")
        dst_boot = os.path.join(mnt, "EFI", "Microsoft", "Boot")
        os.makedirs(dst_boot, exist_ok=True)
        for f in BOOT_FILES:
            if os.path.exists(os.path.join(src_boot, f)):
                shutil.copyfile(os.path.join(src_boot, f), os.path.join(dst_boot, f))
        for d in BOOT_DIRS:
            if os.path.isdir(os.path.join(src_boot, d)):
                shutil.copytree(os.path.join(src_boot, d), os.path.join(dst_boot, d), dirs_exist_ok=True)
        open(os.path.join(dst_boot, "win11.tag"), "w").write("Windows 11 ARM64 boot partition\n")
        for f in ("bootmgfw.efi", "BCD"):
            if not filecmp.cmp(os.path.join(src_boot, f), os.path.join(dst_boot, f), shallow=False):
                raise SystemExit(f"ERROR: {f} does not match after copying")
        target = os.path.join(mnt, folder)
        os.makedirs(target, exist_ok=True)
        shutil.copyfile(os.path.join(mnt, "wp64", "bl31.bin"), os.path.join(target, "bl31.bin"))
        shutil.copyfile(bl33, os.path.join(target, "bl33.bin"))
        if not filecmp.cmp(bl33, os.path.join(target, "bl33.bin"), shallow=False):
            raise SystemExit("ERROR: bl33.bin does not match after copying")
        ini = os.path.join(mnt, "bootloader", "ini", f"{folder}.ini")
        open(ini, "w", newline="").write(f"[{name}]\r\nl4t=1\r\nboot_prefixes={folder}/\r\nuart_port=2\r\n")
        shutil.copyfile(icon, os.path.join(mnt, "bootloader", "res", f"{name}.bmp"))
        st = os.statvfs(mnt)
        print("menu:", sorted(os.listdir(os.path.join(mnt, "bootloader", "ini"))))
        print(f"{folder}:", sorted(os.listdir(target)), f"| free on partition 1: {st.f_bavail * st.f_frsize // MIB} MiB")
    finally:
        subprocess.run(["sync"])
        subprocess.run(["dot_clean", "-m", mnt])
        subprocess.run(["umount", mnt])
        os.rmdir(mnt)
    print(f"DONE: Hekate entry \"{name}\"")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("partition", "hekate", "settype"):
        raise SystemExit(__doc__)
    if os.geteuid() != 0:
        raise SystemExit("Run with sudo")
    if sys.argv[1] == "partition":
        disk, expected, slot, start_mib, image = sys.argv[2:7]
        partition(disk, expected, int(slot), int(start_mib), image)
    elif sys.argv[1] == "settype":
        disk, expected, slot, kind, backup = sys.argv[2:7]
        settype(disk, expected, int(slot), int(kind, 0), backup)
    else:
        hekate(*sys.argv[2:10])


if __name__ == "__main__":
    main()
