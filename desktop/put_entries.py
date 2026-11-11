#!/usr/bin/env python3
"""Ставит основной загрузчик в wp/bl33.bin и любое число пробных пунктов меню Hekate.
Каждый пробный пункт — своя папка (копия wp/ со своим bl33.bin) и свой файл
bootloader/ini/<папка>.ini. Существующие файлы меню не меняются.

    sudo python3 -I put_entries.py disk4 62534975488 основной_bl33.bin иконка.bmp \\
        "Windows CPU A=wpc=файл_a.bin" "Windows CPU B=wpd=файл_b.bin"
"""
import filecmp
import os
import shutil
import subprocess
import sys
import tempfile


def find_main(mnt):
    """Пункт меню с boot_prefixes=wp/: (заголовок, строки пункта, перевод строки)."""
    paths = [os.path.join(mnt, "bootloader", "hekate_ipl.ini")]
    ini_dir = os.path.join(mnt, "bootloader", "ini")
    if os.path.isdir(ini_dir):
        paths += sorted(os.path.join(ini_dir, n) for n in os.listdir(ini_dir)
                        if n.lower().endswith(".ini") and not n.startswith("._"))
    for path in paths:
        text = open(path, encoding="utf-8", errors="surrogateescape").read()
        nl = "\r\n" if "\r\n" in text else "\n"
        block = None
        for line in text.split(nl):
            if line.startswith("["):
                if block and any(l.strip() == "boot_prefixes=wp/" for l in block):
                    return block, nl
                block = [line]
            elif block is not None:
                block.append(line)
        if block and any(l.strip() == "boot_prefixes=wp/" for l in block):
            return block, nl
    raise SystemExit("В меню Hekate нет пункта с boot_prefixes=wp/")


def main():
    disk, expected, main_bl33, icon = sys.argv[1:5]
    entries = [arg.split("=", 2) for arg in sys.argv[5:]]
    info = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in info or f"({expected} Bytes)" not in info:
        raise SystemExit("Это не та карта")
    for _, folder, path in entries:
        if not folder.isalnum() or folder == "wp" or os.path.getsize(path) < 100000:
            raise SystemExit(f"Плохой пункт: {folder} {path}")

    mnt = tempfile.mkdtemp(prefix="switch-esp.", dir="/tmp")
    subprocess.run(["mount", "-t", "msdos", f"/dev/{disk}s1", mnt], check=True)
    try:
        block, nl = find_main(mnt)
        main_title = block[0].strip()
        print("Основной пункт:", main_title)
        wp = os.path.join(mnt, "wp")
        shutil.copyfile(os.path.join(wp, "bl33.bin"), os.path.join(wp, "bl33-prev.bin"))
        shutil.copyfile(main_bl33, os.path.join(wp, "bl33.bin"))
        res = os.path.join(mnt, "bootloader", "res")
        os.makedirs(res, exist_ok=True)
        shutil.copyfile(icon, os.path.join(res, main_title.strip("[]") + ".bmp"))
        checks = [(os.path.join(wp, "bl33.bin"), main_bl33)]

        for title, folder, path in entries:
            dst = os.path.join(mnt, folder)
            os.makedirs(dst, exist_ok=True)
            for name in os.listdir(wp):
                src = os.path.join(wp, name)
                if os.path.isfile(src) and not name.startswith(("bl33", "._")):
                    shutil.copyfile(src, os.path.join(dst, name))
            shutil.copyfile(path, os.path.join(dst, "bl33.bin"))
            lines = [f"[{title}]"]
            for line in block[1:]:
                if line.strip().startswith("boot_prefixes="):
                    line = f"boot_prefixes={folder}/"
                if line.strip():
                    lines.append(line)
            ini = os.path.join(mnt, "bootloader", "ini", f"{folder}.ini")
            open(ini, "w", encoding="utf-8", newline="").write(nl.join(lines) + nl)
            shutil.copyfile(icon, os.path.join(res, title + ".bmp"))
            checks.append((os.path.join(dst, "bl33.bin"), path))
            print(f"пункт [{title}] -> {folder}/  ({os.path.basename(path)})")

        for got, want in checks:
            if not filecmp.cmp(got, want, shallow=False):
                raise SystemExit(f"ОШИБКА: {got} не совпал")
        print("ГОТОВО: пункты записаны")
    finally:
        subprocess.run(["sync"])
        subprocess.run(["umount", mnt])
        os.rmdir(mnt)


if __name__ == "__main__":
    main()
