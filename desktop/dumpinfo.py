#!/usr/bin/env python3
"""Summary of a Windows user-mode minidump (.dmp) without WinDbg: the exception (code, address,
thread), the module that holds the address and the offset in it, the instruction word there when
the dump has that memory, and the loaded modules.

    python3 desktop/dumpinfo.py file.dmp [...]
"""
import struct
import sys

STREAM_MODULES, STREAM_EXCEPTION, STREAM_MEMORY64, STREAM_MEMORY = 4, 6, 9, 5


def utf16(data, rva):
    n = struct.unpack_from('<I', data, rva)[0]
    return data[rva + 4:rva + 4 + n].decode('utf-16le', 'replace')


def read(path):
    data = open(path, 'rb').read()
    if data[:4] != b'MDMP':
        raise SystemExit(f'{path}: not a minidump')
    count, rva = struct.unpack_from('<II', data, 8)
    streams = {}
    for i in range(count):
        kind, size, at = struct.unpack_from('<III', data, rva + 12 * i)
        streams[kind] = (at, size)
    modules = []
    if STREAM_MODULES in streams:
        at = streams[STREAM_MODULES][0]
        n = struct.unpack_from('<I', data, at)[0]
        for i in range(n):
            m = at + 4 + 108 * i
            base, size = struct.unpack_from('<QI', data, m)
            name = utf16(data, struct.unpack_from('<I', data, m + 20)[0])
            ver = struct.unpack_from('<IIII', data, m + 24 + 8)
            modules.append((base, size, name, ver))
    exc = None
    if STREAM_EXCEPTION in streams:
        at = streams[STREAM_EXCEPTION][0]
        thread = struct.unpack_from('<I', data, at)[0]
        code, flags = struct.unpack_from('<II', data, at + 8)
        address = struct.unpack_from('<Q', data, at + 8 + 16)[0]
        exc = (thread, code, address)
    ranges = []
    if STREAM_MEMORY64 in streams:
        at = streams[STREAM_MEMORY64][0]
        n, base_rva = struct.unpack_from('<QQ', data, at)
        off = base_rva
        for i in range(n):
            start, size = struct.unpack_from('<QQ', data, at + 16 + 16 * i)
            ranges.append((start, size, off))
            off += size
    if STREAM_MEMORY in streams:
        at = streams[STREAM_MEMORY][0]
        n = struct.unpack_from('<I', data, at)[0]
        for i in range(n):
            start, size, mrva = struct.unpack_from('<QII', data, at + 4 + 16 * i)
            ranges.append((start, size, mrva))
    return data, modules, exc, ranges


def word_at(data, ranges, address):
    for start, size, off in ranges:
        if start <= address and address + 4 <= start + size:
            return struct.unpack_from('<I', data, off + address - start)[0]
    return None


for path in sys.argv[1:]:
    data, modules, exc, ranges = read(path)
    print(f'== {path}')
    if exc:
        thread, code, address = exc
        owner = next((m for m in modules if m[0] <= address < m[0] + m[1]), None)
        where = f'{owner[2]}+0x{address - owner[0]:x}' if owner else 'outside every module'
        print(f'exception 0x{code:08x} at 0x{address:x} ({where}), thread {thread}')
        word = word_at(data, ranges, address)
        if word is not None:
            print(f'instruction word at the address: 0x{word:08x}')
    for base, size, name, ver in modules:
        print(f'  0x{base:016x} {size:9d} {name}')
