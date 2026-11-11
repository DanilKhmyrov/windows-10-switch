"""Helpers for building BCD .reg fragments for the SD card's MBR layout."""
import struct

MIB = 1048576
LOADER = "{7619dcc9-fafe-11d9-b411-000476eba25f}"
BOOTMGR = "{9dea862c-5cdd-4e70-acc1-f32b344d4795}"
# BCD device element for a partition on the MBR disk with signature 0xAE420040;
# the partition offset in bytes goes at offset 32.
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


def element(obj, code, value):
    return (f'[HKEY_LOCAL_MACHINE\\BCD\\Objects\\{obj}\\Elements\\{code}]\n'
            f'"Element"=hex:{hexlist(value)}\n\n')
