#!/usr/bin/env python3
"""Per-MiB checksums of an image, and writing only the changed MiB to the card.

    python3 img_sums.py sums image.img sums.txt
    sudo python3 -I img_sums.py push disk4 62534975488 image.img sums.txt START_MiB
(push writes the MiB whose checksum differs from the saved one and verifies each write by reading it back.)
"""
import hashlib
import os
import subprocess
import sys

MIB = 1048576


def block_sums(path):
    size = os.path.getsize(path)
    out = []
    with open(path, "rb") as f:
        for _ in range(size // MIB):
            out.append(hashlib.sha1(f.read(MIB)).hexdigest())
    return out


def main():
    if sys.argv[1] == "sums":
        image, sums = sys.argv[2:4]
        open(sums, "w").write("\n".join(block_sums(image)) + "\n")
        print("sums:", sums)
        return
    disk, expected, image, sums, start_mib = sys.argv[2:7]
    start = int(start_mib) * MIB
    text = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in text or f"({expected} Bytes)" not in text:
        raise SystemExit("Wrong card")
    old = open(sums).read().split()
    size = os.path.getsize(image)
    if len(old) != size // MIB or start + size > int(expected):
        raise SystemExit("Checksums or size do not match")
    subprocess.run(["diskutil", "unmountDisk", f"/dev/{disk}"], check=True)
    fd = os.open(f"/dev/r{disk}", os.O_RDWR)
    changed = 0
    with open(image, "rb") as src:
        for i in range(size // MIB):
            block = src.read(MIB)
            if hashlib.sha1(block).hexdigest() == old[i]:
                continue
            os.pwrite(fd, block, start + i * MIB)
            if os.pread(fd, MIB, start + i * MIB) != block:
                raise SystemExit(f"ERROR: MiB {i} does not match after writing")
            changed += 1
    os.fsync(fd)
    os.close(fd)
    print(f"DONE: changed MiB written: {changed}")


if __name__ == "__main__":
    main()
