#!/usr/bin/env python3
"""Updates a partition image from the card: reads the whole partition and writes into the image only
the MiB whose checksum differs from the saved one. Only reads the card.
Afterwards the image checksums match the card, and img_sums.py push writes back only
what was changed in the image.

    sudo python3 -I sync_from_card.py disk4 62534975488 image.img sums.txt START_MiB
"""
import hashlib
import os
import subprocess
import sys

MIB = 1048576


def main():
    disk, expected, image, sums, start_mib = sys.argv[1:6]
    start = int(start_mib) * MIB
    text = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in text or f"({expected} Bytes)" not in text:
        raise SystemExit("Wrong card")
    old = open(sums).read().split()
    size = os.path.getsize(image)
    if len(old) != size // MIB or start + size > int(expected):
        raise SystemExit("Checksums or size do not match")
    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    src = os.open(f"/dev/r{disk}", os.O_RDONLY)
    dst = os.open(image, os.O_RDWR)
    new = []
    changed = 0
    total = size // MIB
    for i in range(total):
        block = os.pread(src, MIB, start + i * MIB)
        if len(block) != MIB:
            raise SystemExit(f"ERROR: short read at MiB {i}")
        digest = hashlib.sha1(block).hexdigest()
        if digest != old[i]:
            os.pwrite(dst, block, i * MIB)
            changed += 1
        new.append(digest)
        if i % 2048 == 0:
            print(f"  {i // 1024} of {total // 1024} GiB, changed MiB: {changed}", flush=True)
    os.fsync(dst)
    os.close(dst)
    os.close(src)
    tmp = sums + ".new"
    open(tmp, "w").write("\n".join(new) + "\n")
    os.replace(tmp, sums)
    owner = os.environ.get("SUDO_UID"), os.environ.get("SUDO_GID")
    if all(owner):
        os.chown(sums, int(owner[0]), int(owner[1]))
    print(f"DONE: changed MiB: {changed}, checksums updated")


if __name__ == "__main__":
    main()
