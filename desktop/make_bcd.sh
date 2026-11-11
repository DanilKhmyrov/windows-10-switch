#!/bin/bash
# Runs inside the switch-wp-drivers container. Builds the BCD for Windows 10 ARM32 from the
# IoT Core BCD: the loader points at the 10815 MiB partition, signature checks are relaxed.
#   make_bcd.sh source_bcd output_BCD
set -euo pipefail
SRC="$1"; OUT="$2"; HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
cp "$SRC" "$OUT"
python3 -I - "$HERE" "$TMP/w32.reg" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import bcdlib as p
L = p.LOADER
out = open(sys.argv[2], "w")
out.write("Windows Registry Editor Version 5.00\n\n")
for code in ("11000001", "21000001"):
    out.write(p.element(L, code, p.device(10815)))
out.write(f'[HKEY_LOCAL_MACHINE\\BCD\\Objects\\{L}\\Elements\\12000002]\n"Element"="\\\\windows\\\\system32\\\\winload.efi"\n\n')
for code, value in (("16000048", b"\x01"), ("16000049", b"\x01"), ("16000060", b"\x01"),
                    ("25000020", bytes([3, 0, 0, 0, 0, 0, 0, 0])),
                    ("17000077", bytes([0x75, 0, 0, 0x15, 0, 0, 0, 0]))):
    out.write(p.element(L, code, value))
PY
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\BCD' "$OUT" "$TMP/w32.reg"
printf '%s\n' 'cd \Objects\{9dea862c-5cdd-4e70-acc1-f32b344d4795}\Elements\24000002' del \
    'cd \Objects\{7619dcc9-fafe-11d9-b411-000476eba25f}\Elements\260000b0' del commit | hivexsh -w "$OUT"
echo ok
