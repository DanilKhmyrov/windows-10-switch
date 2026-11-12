#!/bin/bash
# Builds switchbt.sys (ARM64 KMDF 1.15 Bluetooth transport for the BCM4356A3 on UART-D, under the
# inbox BthMini) from the SwitchBluetooth sources of the winx project
# (github.com/ruje0504-2/Windows-for-Switch-Drivers, drivers/SwitchBluetooth, GPL-2.0) and test-signs it.
#
#   drivers/build_bt.sh SWITCHBT_SRC WDK_C SDK_C OUT_DIR
#
# SWITCHBT_SRC  checkout of drivers/SwitchBluetooth (its tools/kmdf_support.c sits two levels up)
# WDK_C, SDK_C  the "c" folder of the NuGet packages Microsoft.Windows.WDK.ARM64 and
#               Microsoft.Windows.SDK.CPP, version 10.0.26100
# Same tools and test certificate as build_wifi.sh.
set -euo pipefail
SRC="$(cd "$1" && pwd)"; WDK="$(cd "$2" && pwd)"; SDK="$(cd "$3" && pwd)"; mkdir -p "$4"; OUT="$(cd "$4" && pwd)"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
LLVM="${LLVM:-/opt/homebrew/opt/llvm/bin}"
V=10.0.26100.0
I="$WDK/Include/$V"; SI="$SDK/Include/$V"
OBJ="$OUT/obj-bt"; rm -rf "$OBJ"; mkdir -p "$OBJ"

# The flags of the winx Build-Driver.ps1 (NTDDI 0x0A000008, KMDF 1.15).
FLAGS=(--target=aarch64-pc-windows-msvc /c /kernel /GS- /Gy /Zl /O2 /W4 /WX
    -Wno-unused-parameter -Wno-microsoft-anon-tag -Wno-ignored-pragma-intrinsic -Wno-pragma-pack
    -Wno-invalid-token-paste -Wno-unknown-pragmas -Wno-ignored-attributes -Wno-nonportable-include-path
    /D_ARM64_ /DARM64 /D_WIN64 /DNTDDI_VERSION=0x0A000008 /D_WIN32_WINNT=0x0A00 /DWINVER=0x0A00
    /DKMDF_VERSION_MAJOR=1 /DKMDF_VERSION_MINOR=15 /DPOOL_NX_OPTIN=1
    "/imsvc$I/km/crt" "/imsvc$I/km" "/imsvc$SI/shared" "/imsvc$I/shared" "/imsvc$WDK/Include/wdf/kmdf/1.15")
"$LLVM/clang-cl" "${FLAGS[@]}" "/Fo$OBJ/switchbt.obj" -- "$SRC/src/switchbt.c"
"$LLVM/clang-cl" --target=aarch64-pc-windows-msvc /c /GS- /Zl "/Fo$OBJ/kmdf_support.o" -- "$SRC/../../tools/kmdf_support.c"

docker run --rm -v "$WDK:/wdk:ro" -v "$OUT:/out" -v "$PROJECT/drivers/test-cert:/cert:ro" switch-wp-drivers bash -c '
set -e
km=/wdk/Lib/10.0.26100.0/km/ARM64; wdf=/wdk/Lib/wdf/kmdf/ARM64/1.15
cd /out/obj-bt
lld-link-14 /nologo /driver /subsystem:native,10.0 /machine:arm64 /entry:FxDriverEntry /nodefaultlib \
    /opt:ref /opt:icf /tsaware:no /section:.text,ERP /section:.rdata,RP /section:.data,RWP \
    /section:.pdata,RP /section:INIT,ERD /timestamp:0 /out:switchbt-unsigned.sys \
    switchbt.obj kmdf_support.o $wdf/WdfDriverEntry.lib $wdf/WdfLdr.lib \
    $km/ntoskrnl.lib $km/hal.lib $km/ntstrsafe.lib $km/bufferoverflowfastfailk.lib
llvm-objdump-14 -h switchbt-unsigned.sys | grep -q "\.reloc" || { echo "ERROR: no .reloc section"; exit 1; }
rm -f /out/switchbt.sys
osslsigncode sign -certs /cert/wifi-chain.crt -key /cert/wifi.key -h sha256 -in switchbt-unsigned.sys -out /out/switchbt.sys >/dev/null
'
cp "$PROJECT/drivers/switchbt/switchbt.inf" "$OUT/"
echo "Signed ARM64 driver: $OUT/switchbt.sys"
