#!/usr/bin/env python3
"""Cleans up the Hekate menu after experiments:
- the main entry (boot_prefixes=wp/) is renamed to "Windows 10 ARM32" and gets the given bl33;
- test entries (ini wp-ramtest, wpb, wpc, wpd and their
  folders with icons) are removed. The previous menu file is kept as .bak.

    sudo python3 -I finalize_menu.py disk4 62534975488 bl33.bin icon.bmp
"""
import filecmp
import os
import shutil
import subprocess
import sys
import tempfile

TITLE = "Windows 10 ARM32"
TEST_INIS = ("wp-ramtest.ini", "wpb.ini", "wpc.ini", "wpd.ini")
TEST_DIRS = ("wpb", "wpc", "wpd")
TEST_ICONS = ("Windows RAM test.bmp", "Windows safe.bmp", "Windows CPU A.bmp", "Windows CPU B.bmp",
              "Windows Phone Test.bmp", "Win 1785.bmp", "Win 1785 RAM1600.bmp", "Windows 10 ARM32 1420.bmp")


def main():
    disk, expected, bl33, icon = sys.argv[1:5]
    info = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in info or f"({expected} Bytes)" not in info:
        raise SystemExit("Wrong card")
    if os.path.getsize(bl33) < 100000:
        raise SystemExit("Suspiciously small bl33")

    mnt = tempfile.mkdtemp(prefix="switch-esp.", dir="/tmp")
    subprocess.run(["mount", "-t", "msdos", f"/dev/{disk}s1", mnt], check=True)
    try:
        ini_dir = os.path.join(mnt, "bootloader", "ini")
        main_ini = os.path.join(ini_dir, "wp.ini")
        text = open(main_ini, encoding="utf-8", errors="surrogateescape").read()
        if "boot_prefixes=wp/" not in text:
            raise SystemExit("wp.ini has no boot_prefixes=wp/, leaving it alone")
        nl = "\r\n" if "\r\n" in text else "\n"
        lines = text.split(nl)
        start = next(i for i, l in enumerate(lines) if l.startswith("["))
        lines[start] = f"[{TITLE}]"
        shutil.copyfile(main_ini, main_ini + ".bak")
        open(main_ini, "w", encoding="utf-8", errors="surrogateescape", newline="").write(nl.join(lines))

        wp = os.path.join(mnt, "wp")
        shutil.copyfile(os.path.join(wp, "bl33.bin"), os.path.join(wp, "bl33-prev.bin"))
        shutil.copyfile(bl33, os.path.join(wp, "bl33.bin"))
        res = os.path.join(mnt, "bootloader", "res")
        shutil.copyfile(icon, os.path.join(res, TITLE + ".bmp"))

        for name in TEST_INIS:
            path = os.path.join(ini_dir, name)
            if os.path.exists(path):
                os.remove(path)
                print("removed entry", name)
        # macOS metadata files (._*) next to menu entries: Hekate could take them for .ini files.
        for name in os.listdir(ini_dir):
            if name.startswith("._"):
                os.remove(os.path.join(ini_dir, name))
        for name in TEST_ICONS:
            path = os.path.join(res, name)
            if os.path.exists(path):
                os.remove(path)
        for name in TEST_DIRS:
            path = os.path.join(mnt, name)
            if os.path.isdir(path):
                shutil.rmtree(path)
                print("removed folder", name)

        if not filecmp.cmp(os.path.join(wp, "bl33.bin"), bl33, shallow=False):
            raise SystemExit("ERROR: wp/bl33.bin does not match")
        print(open(main_ini, encoding="utf-8", errors="replace").read())
        print("Menu entries:", sorted(os.listdir(ini_dir)))
        print(f"DONE: the menu has one entry \"{TITLE}\"")
    finally:
        subprocess.run(["sync"])
        subprocess.run(["umount", mnt])
        os.rmdir(mnt)


if __name__ == "__main__":
    main()
