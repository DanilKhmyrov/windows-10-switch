#!/usr/bin/env python3
"""Builds bl33.bin. Needs only clang, which macOS already has.

    python3 build.py test                  # bl33 for a colour test
    python3 build.py chain NintendoSwitch.fd  # bl33 with the 64-bit UEFI inside
    python3 build.py chain32 NintendoSwitch-arm.fd  # bl33 with the 32-bit UEFI inside
    python3 build.py chain32 NintendoSwitch-arm-release.fd --clean  # clean boot screen
"""
import argparse
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
UEFI_MAX_SIZE = 0xE0000  # size of the UEFI region in NintendoSwitch.fdf
SHT_RELA, SHT_REL = 4, 9


def extract_text(obj: Path) -> bytes:
    """Extracts the code from an ELF file and checks that it needs no linking."""
    data = obj.read_bytes()
    if data[:4] != b"\x7fELF":
        raise SystemExit(f"{obj}: not an ELF file")
    is_64 = data[4] == 2
    if is_64:
        shoff = struct.unpack_from("<Q", data, 0x28)[0]
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    else:
        shoff = struct.unpack_from("<I", data, 0x20)[0]
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x2E)

    sections = []
    for i in range(shnum):
        base = shoff + i * shentsize
        if is_64:
            name, kind = struct.unpack_from("<II", data, base)
            offset, size = struct.unpack_from("<QQ", data, base + 0x18)
        else:
            name, kind = struct.unpack_from("<II", data, base)
            offset, size = struct.unpack_from("<II", data, base + 0x10)
        sections.append((name, kind, offset, size))

    names_offset = sections[shstrndx][2]

    def section_name(entry):
        start = names_offset + entry[0]
        return data[start:data.index(b"\0", start)].decode()

    named = {section_name(s): s for s in sections}
    for bad in (s for s in sections if s[1] in (SHT_RELA, SHT_REL)):
        if section_name(bad) in (".rela.text", ".rel.text") and bad[3]:
            raise SystemExit("The code still has references that need a linker")
    _, _, offset, size = named[".text"]
    return data[offset:offset + size]


def assemble(source: Path, target: str, out: Path, *flags: str) -> bytes:
    subprocess.run(
        ["clang", "-target", target, "-c", str(source), "-o", str(out), *flags],
        check=True,
    )
    return extract_text(out)


def build(mode: str, payload: bytes, output: Path, clean: bool = False, delay_ms: int = 0,
          uhs: str = "") -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        flags = [
            f"-DTEST_MODE={1 if mode == 'test' else 0}",
            f"-DCHAIN_A32={1 if mode == 'chain32' else 0}",
            f"-DCLEAN={1 if clean else 0}",
            f"-DDELAY_MS={delay_ms}",
            f"-DUHS_MODE={ {'': 0, 'ddr50': 1, 'sdr50-48': 2}[uhs] }",
        ]
        if mode == "test":
            a32 = assemble(HERE / "a32.S", "armv7a-none-eabi", tmp_path / "a32.o")
            a32_bin = tmp_path / "a32.bin"
            a32_bin.write_bytes(a32)
            flags.append(f'-DA32_BIN="{a32_bin}"')
        shim = bytearray(
            assemble(HERE / "shim.S", "aarch64-none-elf", tmp_path / "shim.o", *flags)
        )

    if shim[8:16] != b"WPSHIM01":
        raise SystemExit("The shim header was assembled incorrectly")
    while len(shim) % 8:
        shim.append(0)
    struct.pack_into("<Q", shim, 0x18, len(payload))
    output.write_bytes(bytes(shim) + payload)
    print(f"{output}: {len(shim)} bytes of shim + {len(payload)} bytes of UEFI")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["test", "chain", "chain32"])
    parser.add_argument("uefi", nargs="?", type=Path, help="NintendoSwitch.fd")
    parser.add_argument("-o", "--output", type=Path, default=HERE / "bl33.bin")
    parser.add_argument("--delay-ms", type=int, default=0,
                        help="delay before starting UEFI (waits for memory training on Mariko)")
    parser.add_argument("--clean", action="store_true",
                        help="no colour marks: just a black screen (errors stay coloured)")
    parser.add_argument("--uhs", choices=["ddr50", "sdr50-48"], default="",
                        help="experimental SD UHS-I under Windows: DDR50, or SDR50 at 48 MHz (1.8 V test)")
    args = parser.parse_args()

    payload = b""
    if args.mode in ("chain", "chain32"):
        if not args.uefi:
            sys.exit("This mode needs a UEFI file (.fd)")
        payload = args.uefi.read_bytes()
        if not payload or len(payload) > UEFI_MAX_SIZE:
            sys.exit(f"Wrong UEFI size: {len(payload)} bytes")
    build(args.mode, payload, args.output, args.clean, args.delay_ms, args.uhs)


if __name__ == "__main__":
    main()
