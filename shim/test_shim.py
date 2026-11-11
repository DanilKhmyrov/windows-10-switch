#!/usr/bin/env python3
"""Запускает собранную прокладку в эмуляторе процессора, без консоли.

Проверяет логику: цвета, вывод в UART, копирование UEFI и переход на него.
Не проверяет настоящее железо, Hekate и BL31.

    pip install unicorn
    python3 test_shim.py
"""
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

from unicorn import (
    UC_ARCH_ARM, UC_ARCH_ARM64, UC_HOOK_CODE, UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE,
    UC_MODE_ARM, Uc, UcError,
)
from unicorn.arm64_const import (
    UC_ARM64_REG_PC, UC_ARM64_REG_PSTATE, UC_ARM64_REG_X21, UC_CPU_ARM64_A72,
)
from unicorn.arm_const import UC_ARM_REG_R0, UC_CPU_ARM_CORTEX_A15

HERE = Path(__file__).resolve().parent
BL33 = 0xAA000000
UEFI = 0x80110000
FB = 0xF5A00000
CAR = 0x60006000
UART = 0x70006040
EL2H = 0x3C9
PAGE = 0x1000
CMP_X21_2 = 0xF1000ABF  # инструкция cmp x21, #2


def build(mode, uefi=None):
    out = Path(tempfile.mkdtemp()) / "bl33.bin"
    command = [sys.executable, str(HERE / "build.py"), mode]
    if uefi:
        command.append(str(uefi))
    subprocess.run([*command, "-o", str(out)], check=True, capture_output=True)
    return out.read_bytes()


class Machine:
    def __init__(self, arch, mode, cpu, clk_enable=True):
        self.uc = Uc(arch, mode)
        self.uc.ctl_set_cpu_model(cpu)
        self.uart = bytearray()
        self.colors = []
        self.clk_enable = clk_enable
        self.uart_touched = False
        self.uc.mem_map(CAR, PAGE)
        self.uc.mem_write(CAR + 0x10, struct.pack("<I", (1 << 7) if clk_enable else 0))
        self.uc.mem_map(UART & ~(PAGE - 1), PAGE)
        self.uc.mem_map(FB, 0x384000)
        self.uc.hook_add(UC_HOOK_MEM_WRITE, self.on_write)
        self.uc.hook_add(UC_HOOK_MEM_READ, self.on_read)

    def on_read(self, uc, _access, address, _size, _value, _data):
        if UART <= address < UART + 0x40:
            self.uart_touched = True
            if address == UART + 0x14:
                uc.mem_write(address, struct.pack("<I", 0x60))

    def on_write(self, _uc, _access, address, _size, value, _data):
        if UART <= address < UART + 0x40:
            self.uart_touched = True
            lcr = self.last_lcr if hasattr(self, "last_lcr") else 0
            if address == UART + 0x0C:
                self.last_lcr = value
            elif address == UART and not lcr & 0x80:
                self.uart.append(value & 0xFF)
        elif address == FB:
            self.colors.append(value & 0xFFFFFFFF)


def machine_a64(image, clk_enable=True, fake_el2=True):
    m = Machine(UC_ARCH_ARM64, UC_MODE_ARM, UC_CPU_ARM64_A72, clk_enable)
    m.uc.mem_map(BL33, (len(image) + PAGE) & ~(PAGE - 1))
    m.uc.mem_map(UEFI, 0x100000)
    m.uc.mem_write(BL33, image)
    m.uc.reg_write(UC_ARM64_REG_PSTATE, EL2H)
    if fake_el2:
        # Эмулятор работает только в EL1, поэтому перед проверкой уровня
        # подставляем значение 2, которое задаёт Hekate на настоящей консоли.
        check = BL33 + image.index(struct.pack("<I", CMP_X21_2))
        m.uc.hook_add(
            UC_HOOK_CODE,
            lambda uc, _a, _s, _d: uc.reg_write(UC_ARM64_REG_X21, 2),
            begin=check,
            end=check,
        )
    return m


def run(m, start, stop, count=30_000_000):
    try:
        m.uc.emu_start(start, stop, count=count)
    except UcError as error:
        return error
    return None


def test_header():
    image = build("test")
    assert image[8:16] == b"WPSHIM01"
    assert struct.unpack_from("<I", image, 0x10)[0] == 0, "+0x10 должно быть нулём"
    print("ok: заголовок и нулевое смещение DTB")


def test_chain():
    payload = bytes((i * 7) & 0xFF for i in range(4096))
    with tempfile.NamedTemporaryFile(suffix=".fd") as fd:
        fd.write(payload)
        fd.flush()
        image = build("chain", fd.name)
    m = machine_a64(image)
    error = run(m, BL33, UEFI)
    assert error is None, f"сбой: {error}"
    assert m.uc.reg_read(UC_ARM64_REG_PC) == UEFI, "нет перехода на UEFI"
    assert bytes(m.uc.mem_read(UEFI, len(payload))) == payload, "UEFI скопирован неверно"
    assert m.colors == [0xFF00FF00, 0xFF00FFFF], m.colors
    text = m.uart.decode()
    # В эмуляторе здесь будет CurrentEL=1: значение подменяется уже после печати.
    assert "CurrentEL=" in text and "jumping to UEFI" in text, text
    print("ok: копирование UEFI, цвета, UART, переход")
    print("   UART:", text.strip().replace("\r\n", " | "))


def test_uart_disabled():
    with tempfile.NamedTemporaryFile(suffix=".fd") as fd:
        fd.write(b"\x00" * 64)
        fd.flush()
        image = build("chain", fd.name)
    m = machine_a64(image, clk_enable=False)
    error = run(m, BL33, UEFI)
    assert error is None, f"сбой: {error}"
    assert not m.uart_touched, "код обратился к выключенному UART"
    print("ok: выключенный UART не трогаем")


def test_wrong_el_stops():
    with tempfile.NamedTemporaryFile(suffix=".fd") as fd:
        fd.write(b"\x00" * 64)
        fd.flush()
        image = build("chain", fd.name)
    m = machine_a64(image, fake_el2=False)
    run(m, BL33, UEFI, count=8_000_000)
    assert m.uc.reg_read(UC_ARM64_REG_PC) != UEFI, "ушли в UEFI с неверным уровнем"
    assert m.colors == [0xFF00FF00, 0xFFFF00FF], m.colors
    print("ok: при неверном уровне экран маджента, запуска UEFI нет")


def test_a32_blob():
    tmp = Path(tempfile.mkdtemp()) / "a32.o"
    sys.path.insert(0, str(HERE))
    import build as builder

    code = builder.assemble(HERE / "a32.S", "armv7a-none-eabi", tmp)
    m = Machine(UC_ARCH_ARM, UC_MODE_ARM, UC_CPU_ARM_CORTEX_A15)
    address = 0x10000
    m.uc.mem_map(address, 0x10000)
    m.uc.mem_write(address, code)
    m.uc.reg_write(UC_ARM_REG_R0, 1)
    halt = address + code.index(struct.pack("<I", 0xE320F002))  # инструкция wfe
    error = run(m, address, halt)
    assert error is None, f"сбой: {error}"
    assert m.colors == [0xFFFFFFFF], m.colors
    assert "AArch32 OK" in m.uart.decode(), m.uart
    print("ok: 32-битная часть рисует белый и пишет в UART")


if __name__ == "__main__":
    test_header()
    test_chain()
    test_uart_disabled()
    test_wrong_el_stops()
    test_a32_blob()
    print("Все проверки в эмуляторе пройдены.")
