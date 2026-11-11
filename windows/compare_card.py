#!/usr/bin/env python3
"""Показывает, какие мегабайты карты отличаются от образа. На карту не пишет.

    sudo python3 -I compare_card.py rdisk4 disk.img
"""
import sys

MIB = 1024 * 1024


def main():
    disk, image_path = sys.argv[1:3]
    ranges = []
    with open(f"/dev/{disk}", "rb", buffering=0) as card, open(image_path, "rb") as image:
        position = 0
        while True:
            expected = image.read(MIB)
            if not expected:
                break
            actual = card.read(len(expected))
            if actual != expected:
                if ranges and ranges[-1][1] == position:
                    ranges[-1][1] = position + 1
                else:
                    ranges.append([position, position + 1])
            position += 1
    print(f"Сравнено МиБ: {position}, отличающихся участков: {len(ranges)}")
    for first, end in ranges[:40]:
        print(f"  с {first} по {end} МиБ")


if __name__ == "__main__":
    main()
