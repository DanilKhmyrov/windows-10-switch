#!/usr/bin/env python3
"""Ставит два загрузчика сразу: основной в wp/bl33.bin (пункт «Windows Phone Test»)
и пробный в wpb/bl33.bin (новый пункт меню Hekate «Windows RAM test»).
Если пробный повиснет, можно просто выбрать обычный пункт.

    sudo python3 -I put_test_entry.py disk4 62534975488 основной_bl33.bin пробный_bl33.bin [иконка.bmp]

Иконка (необязательно) кладётся как bootloader/res/<название пункта>.bmp: Nyx берёт её сам.

Существующие файлы меню Hekate не меняются: новый пункт кладётся в bootloader/ini/wp-ramtest.ini.
"""
import filecmp
import os
import shutil
import subprocess
import sys
import tempfile

TEST_SECTION = "[Windows RAM test]"


def main():
    disk, expected, main_bl33, test_bl33 = sys.argv[1:5]
    icon = sys.argv[5] if len(sys.argv) > 5 else None
    info = subprocess.run(["diskutil", "info", disk], check=True, capture_output=True, text=True).stdout
    if "SD RAW" not in info or f"({expected} Bytes)" not in info:
        raise SystemExit("Это не та карта")
    for path in (main_bl33, test_bl33):
        if os.path.getsize(path) < 100000:
            raise SystemExit(f"Подозрительно маленький файл: {path}")

    mnt = tempfile.mkdtemp(prefix="switch-esp.", dir="/tmp")
    subprocess.run(["mount", "-t", "msdos", f"/dev/{disk}s1", mnt], check=True)
    try:
        # Пункты меню лежат либо в hekate_ipl.ini, либо в отдельных файлах bootloader/ini/*.ini.
        candidates = [os.path.join(mnt, "bootloader", "hekate_ipl.ini")]
        ini_dir = os.path.join(mnt, "bootloader", "ini")
        if os.path.isdir(ini_dir):
            candidates += sorted(os.path.join(ini_dir, n) for n in os.listdir(ini_dir)
                                 if n.lower().endswith(".ini") and not n.startswith("._"))
        start = -1
        for ini_path in candidates:
            ini = open(ini_path, encoding="utf-8", errors="surrogateescape").read()
            nl = "\r\n" if "\r\n" in ini else "\n"
            pos = 0
            while start < 0:
                pos = ini.find("[", pos)
                if pos < 0:
                    break
                end = ini.find(nl + "[", pos + 1)
                block = ini[pos:] if end < 0 else ini[pos:end]
                if any(l.strip() == "boot_prefixes=wp/" for l in block.split(nl)):
                    start = pos
                pos += 1
            if start >= 0:
                break
        if start < 0:
            for path in candidates:
                print("----", path)
                print(open(path, encoding="utf-8", errors="replace").read())
            raise SystemExit("В меню Hekate нет пункта с boot_prefixes=wp/")
        print("Файл меню:", ini_path)
        main_title = ini[start:ini.index("]", start) + 1]
        print("Основной пункт:", main_title)

        # Основной загрузчик.
        wp = os.path.join(mnt, "wp")
        shutil.copyfile(os.path.join(wp, "bl33.bin"), os.path.join(wp, "bl33-prev.bin"))
        shutil.copyfile(main_bl33, os.path.join(wp, "bl33.bin"))

        # Пробный: та же папка, что wp/, но со своим bl33.
        wpb = os.path.join(mnt, "wpb")
        os.makedirs(wpb, exist_ok=True)
        for name in os.listdir(wp):
            if name.startswith("bl33") or name.startswith("._"):
                continue
            src = os.path.join(wp, name)
            if os.path.isfile(src):
                shutil.copyfile(src, os.path.join(wpb, name))
        shutil.copyfile(test_bl33, os.path.join(wpb, "bl33.bin"))

        # Пункт меню: копия основного с другой папкой, в отдельном файле bootloader/ini/.
        test_ini = os.path.join(mnt, "bootloader", "ini", "wp-ramtest.ini")
        end = ini.find(nl + "[", start + len(main_title))
        block = ini[start:] if end < 0 else ini[start:end]
        new = [TEST_SECTION]
        for line in block.split(nl)[1:]:
            if line.strip().startswith("boot_prefixes="):
                line = "boot_prefixes=wpb/"
            if line.strip():
                new.append(line)
        if "boot_prefixes=wpb/" not in new:
            raise SystemExit("В основном пункте нет boot_prefixes, не трогаю меню")
        os.makedirs(os.path.dirname(test_ini), exist_ok=True)
        open(test_ini, "w", encoding="utf-8", newline="").write(nl.join(new) + nl)
        print("---- новый пункт", test_ini)
        print(nl.join(new))

        if icon:
            res = os.path.join(mnt, "bootloader", "res")
            os.makedirs(res, exist_ok=True)
            for title in (main_title, TEST_SECTION):
                shutil.copyfile(icon, os.path.join(res, title.strip("[]") + ".bmp"))
                print("иконка:", title.strip("[]") + ".bmp")

        for got, want in ((os.path.join(wp, "bl33.bin"), main_bl33), (os.path.join(wpb, "bl33.bin"), test_bl33)):
            if not filecmp.cmp(got, want, shallow=False):
                raise SystemExit(f"ОШИБКА: {got} не совпал")
        print("ГОТОВО: основной в wp/, пробный в wpb/ (пункт «Windows RAM test»)")
    finally:
        subprocess.run(["sync"])
        subprocess.run(["umount", mnt])
        os.rmdir(mnt)


if __name__ == "__main__":
    main()
