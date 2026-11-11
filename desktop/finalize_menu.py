#!/usr/bin/env python3
"""Наводит порядок в меню Hekate после испытаний:
- основной пункт (boot_prefixes=wp/) переименовывается в «Windows 10 ARM32», его bl33 — заданный файл;
- пробные пункты, созданные put_test_entry.py / put_entries.py (ini wp-ramtest, wpb, wpc, wpd и их
  папки с иконками), удаляются. Прежний файл меню сохраняется как .bak.

    sudo python3 -I finalize_menu.py disk4 62534975488 bl33.bin иконка.bmp
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
        raise SystemExit("Это не та карта")
    if os.path.getsize(bl33) < 100000:
        raise SystemExit("Подозрительно маленький bl33")

    mnt = tempfile.mkdtemp(prefix="switch-esp.", dir="/tmp")
    subprocess.run(["mount", "-t", "msdos", f"/dev/{disk}s1", mnt], check=True)
    try:
        ini_dir = os.path.join(mnt, "bootloader", "ini")
        main_ini = os.path.join(ini_dir, "wp.ini")
        text = open(main_ini, encoding="utf-8", errors="surrogateescape").read()
        if "boot_prefixes=wp/" not in text:
            raise SystemExit("В wp.ini нет boot_prefixes=wp/, не трогаю")
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
                print("удалён пункт", name)
        # Служебные файлы macOS (._*) рядом с пунктами меню: Hekate мог бы принять их за .ini.
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
                print("удалена папка", name)

        if not filecmp.cmp(os.path.join(wp, "bl33.bin"), bl33, shallow=False):
            raise SystemExit("ОШИБКА: wp/bl33.bin не совпал")
        print(open(main_ini, encoding="utf-8", errors="replace").read())
        print("Пункты меню:", sorted(os.listdir(ini_dir)))
        print(f"ГОТОВО: в меню один пункт «{TITLE}»")
    finally:
        subprocess.run(["sync"])
        subprocess.run(["umount", mnt])
        os.rmdir(mnt)


if __name__ == "__main__":
    main()
