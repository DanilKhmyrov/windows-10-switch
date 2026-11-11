#!/usr/bin/env python3
"""Готовит .reg и команды для BCD и реестра образа телефона под разметку MBR карты."""
import struct
import sys

MIB = 1048576
SIGNATURE = bytes.fromhex("400042ae")
ESP_MIB = 2
MAINOS_MIB = 3601
DATA_MIB = 5465
LOADER = "{7619dcc9-fafe-11d9-b411-000476eba25f}"
BOOTMGR = "{9dea862c-5cdd-4e70-acc1-f32b344d4795}"
GLOBAL = "{7ea2e1ac-2e61-4728-aaa3-896d9d0a9f0e}"
ESP_GUID = "{8183040a-8b44-4592-92f7-c6d9ee0560f7}"
MAIN_GUID = "{a76b8ce2-0187-4c13-8fca-8651c9b0620a}"
DATA_GUID = "{9f7e4f80-e585-4682-9bf3-10352a9698e8}"
TEMPLATE = bytes.fromhex(
    "0000000000000000000000000000000006000000000000004800000000000000"
    "0000800400000000000000000000000000000000" "01000000" "400042ae"
    "00000000000000000000000000000000000000000000000000000000")


def hexlist(data):
    return ",".join(f"{b:02x}" for b in data)


def device(mib):
    data = bytearray(TEMPLATE)
    data[32:40] = struct.pack("<Q", mib * MIB)
    return bytes(data)


def mounted(mib):
    return SIGNATURE + struct.pack("<Q", mib * MIB)


def element(obj, code, value):
    return (f'[HKEY_LOCAL_MACHINE\\BCD\\Objects\\{obj}\\Elements\\{code}]\n'
            f'"Element"=hex:{hexlist(value)}\n\n')


def write_bcd(path):
    with open(path, "w") as out:
        out.write("Windows Registry Editor Version 5.00\n\n")
        out.write(element(LOADER, "11000001", device(MAINOS_MIB)))
        out.write(element(LOADER, "21000001", device(MAINOS_MIB)))
        out.write(element(BOOTMGR, "11000001", device(ESP_MIB)))
        out.write(element(GLOBAL, "16000049", b"\x01"))


def write_system(path):
    root = "HKEY_LOCAL_MACHINE\\SYSTEM\\MountedDevices"
    entries = [("\\\\DosDevices\\\\C:", MAINOS_MIB), ("\\\\DosDevices\\\\U:", DATA_MIB),
               (f"\\\\??\\\\Volume{MAIN_GUID}", MAINOS_MIB), (f"\\\\??\\\\Volume{DATA_GUID}", DATA_MIB),
               (f"\\\\??\\\\Volume{ESP_GUID}", ESP_MIB)]
    with open(path, "w") as out:
        out.write(f"Windows Registry Editor Version 5.00\n\n[{root}]\n")
        for name, mib in entries:
            out.write(f'"{name}"=hex:{hexlist(mounted(mib))}\n')


if __name__ == "__main__":
    write_bcd(sys.argv[1])
    write_system(sys.argv[2])
