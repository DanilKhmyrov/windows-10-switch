#!/bin/bash
# Runs inside the switch-wp-drivers container. Builds the BCD for Windows 10 ARM64 from the
# BCD-Template shipped in the Windows image (Windows\System32\config\BCD-Template): the boot
# manager lives on the small FAT partition, the system on the NTFS partition. Signature checks
# are relaxed (test-signed drivers).
#   make_bcd64.sh BCD-Template output_BCD DISK_SIGNATURE ARM64_PARTITION_MiB BOOT_PARTITION_MiB
# DISK_SIGNATURE is the 32-bit MBR disk signature (setup_card.py prints it), e.g. 0xAE420040.
set -euo pipefail
SRC="$1"; OUT="$2"; SIGNATURE="$3"; OS_MIB="$4"; ESP_MIB="$5"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
cp "$SRC" "$OUT"
python3 -I - "$HERE" "$TMP/w64.reg" "$SIGNATURE" "$OS_MIB" "$ESP_MIB" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import bcdlib as p
signature, os_mib, esp_mib = int(sys.argv[3], 0), int(sys.argv[4]), int(sys.argv[5])
L, B = p.LOADER, p.BOOTMGR
out = open(sys.argv[2], "w")
out.write("Windows Registry Editor Version 5.00\n\n")
# Boot manager: its own partition, default entry = our loader.
out.write(p.element(B, "11000001", p.device(esp_mib, signature)))
out.write(p.string_element(B, "23000003", L))
out.write(p.list_element(B, "24000001", [L]))
out.write(p.element(B, "16000049", b"\x01"))                     # allow prerelease signatures
out.write(p.element(B, "25000004", (30).to_bytes(8, "little")))  # timeout
out.write(p.element(B, "26000020", b"\x00"))                     # no boot menu
out.write(p.element(B, "26000031", b"\x01"))                     # as in the tested BCD
# Windows loader.
out.write(p.object_type(L, 0x10200003))
for code in ("11000001", "21000001"):
    out.write(p.element(L, code, p.device(os_mib, signature)))
out.write(p.string_element(L, "12000002", "\\windows\\system32\\winload.efi"))
out.write(p.string_element(L, "12000004", "Windows 10 ARM64"))
out.write(p.string_element(L, "12000005", "en-US"))
out.write(p.list_element(L, "14000006", [p.BOOTLOADERSETTINGS]))
out.write(p.string_element(L, "22000002", "\\windows"))
for code, value in (("16000010", b"\x00"),    # no boot debugging
                    ("16000048", b"\x01"),    # no integrity checks
                    ("16000049", b"\x01"),    # test signing
                    ("16000060", b"\x01"),
                    ("17000077", bytes([0x75, 0, 0, 0x15, 0, 0, 0, 0])),
                    ("25000020", (3).to_bytes(8, "little")),   # NX policy as in the tested BCD
                    ("250000c2", (1).to_bytes(8, "little")),   # standard boot menu policy
                    ("26000022", b"\x00")):
    out.write(p.element(L, code, value))
PY
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\BCD' "$OUT" "$TMP/w64.reg"
echo ok
