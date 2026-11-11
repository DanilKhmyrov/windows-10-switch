#!/usr/bin/env python3
"""Copies the Windows 10 ARM32 partition from the card to a file and remembers a checksum of every MiB,
so that only the changed regions are written back later (push_win.py).

    sudo python3 -I pull_win.py disk4 62534975488 folder
Only reads the card.
"""
import hashlib
import os
import subprocess
import sys

MIB = 1048576
START, SIZE = 10815 * MIB, 12288 * MIB


def check_card(disk, expected):
    text = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in text or f"({expected} Bytes)" not in text or "Removable" not in text:
        raise SystemExit("Not a Hekate SD card of the expected size")


def main():
    disk, expected, folder = sys.argv[1:4]
    check_card(disk, expected)
    os.makedirs(folder, exist_ok=True)
    image, sums = os.path.join(folder, "win.img"), os.path.join(folder, "win.sums")
    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    fd = os.open(f"/dev/r{disk}", os.O_RDONLY)
    with open(image, "wb") as out, open(sums, "w") as sums_file:
        for index in range(SIZE // MIB):
            block = os.pread(fd, MIB, START + index * MIB)
            if len(block) != MIB:
                raise SystemExit(f"Could not read MiB {index}")
            out.write(block)
            sums_file.write(hashlib.sha1(block).hexdigest() + "\n")
            if index % 512 == 0:
                print(f"\r  copied {index} of {SIZE // MIB} MiB", end="", flush=True)
    os.close(fd)
    uid = int(os.environ.get("SUDO_UID", os.getuid()))
    for path in (folder, image, sums):
        os.chown(path, uid, -1)
    print(f"\nDONE: partition copied to {image}")


if __name__ == "__main__":
    main()
