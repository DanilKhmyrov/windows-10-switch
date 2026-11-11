#!/bin/bash
# Runs inside the switch-wp-drivers container. BCD for Windows 10 ARM64 based on the ARM32 BCD
# (desktop/make_bcd.sh): the boot manager lives on the CRASHDUMP partition (1416 MiB),
# the system on the ARM64 partition. Signature checks are relaxed the same way as on ARM32.
#   make_bcd64.sh BCD_ARM32 output_BCD [ARM64_partition_MiB] [boot_manager_partition_MiB]
set -euo pipefail
SRC="$1"; OUT="$2"; OS_MIB="${3:-23104}"; ESP_MIB="${4:-1416}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
cp "$SRC" "$OUT"
python3 -I - "$HERE" "$TMP/w64.reg" "$OS_MIB" "$ESP_MIB" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import bcdlib as p
os_mib, esp_mib = int(sys.argv[3]), int(sys.argv[4])
out = open(sys.argv[2], "w")
out.write("Windows Registry Editor Version 5.00\n\n")
for code in ("11000001", "21000001"):
    out.write(p.element(p.LOADER, code, p.device(os_mib)))
out.write(p.element(p.BOOTMGR, "11000001", p.device(esp_mib)))
PY
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\BCD' "$OUT" "$TMP/w64.reg"
echo ok
