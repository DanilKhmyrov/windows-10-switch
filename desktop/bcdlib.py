"""Helpers for building BCD .reg fragments for an SD card with an MBR partition table."""
import struct

MIB = 1048576
LOADER = "{7619dcc9-fafe-11d9-b411-000476eba25f}"
BOOTMGR = "{9dea862c-5cdd-4e70-acc1-f32b344d4795}"
BOOTLOADERSETTINGS = "{6efb52bf-1766-41db-a6b3-0ee5eff72bd7}"
# Signature of the test console's card; ARM32 scripts still use it as the default.
DEFAULT_SIGNATURE = 0xAE420040
# BCD device element for a partition on an MBR disk: the partition offset in bytes goes at
# offset 32, the disk signature at offset 56.
TEMPLATE = bytes.fromhex(
    "0000000000000000000000000000000006000000000000004800000000000000"
    "0000800400000000000000000000000000000000" "01000000" "400042ae"
    "00000000000000000000000000000000000000000000000000000000")


def hexlist(data):
    return ",".join(f"{b:02x}" for b in data)


def device(mib, signature=DEFAULT_SIGNATURE):
    data = bytearray(TEMPLATE)
    data[32:40] = struct.pack("<Q", mib * MIB)
    data[56:60] = struct.pack("<I", signature)
    return bytes(data)


def element(obj, code, value):
    """REG_BINARY element (devices, integers, booleans)."""
    return (f'[HKEY_LOCAL_MACHINE\\BCD\\Objects\\{obj}\\Elements\\{code}]\n'
            f'"Element"=hex:{hexlist(value)}\n\n')


def string_element(obj, code, text):
    """REG_SZ element (paths, descriptions, object GUIDs)."""
    value = (text + "\0").encode("utf-16-le")
    return (f'[HKEY_LOCAL_MACHINE\\BCD\\Objects\\{obj}\\Elements\\{code}]\n'
            f'"Element"=hex(1):{hexlist(value)}\n\n')


def list_element(obj, code, items):
    """REG_MULTI_SZ element (lists of object GUIDs)."""
    value = "".join(item + "\0" for item in items).encode("utf-16-le") + b"\0\0"
    return (f'[HKEY_LOCAL_MACHINE\\BCD\\Objects\\{obj}\\Elements\\{code}]\n'
            f'"Element"=hex(7):{hexlist(value)}\n\n')


def object_type(obj, kind):
    """New BCD object: its key, Description with the type, and an empty Elements key."""
    base = f'HKEY_LOCAL_MACHINE\\BCD\\Objects\\{obj}'
    return (f'[{base}]\n\n'
            f'[{base}\\Description]\n"Type"=dword:{kind:08x}\n\n'
            f'[{base}\\Elements]\n\n')
