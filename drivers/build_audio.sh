#!/bin/bash
# Builds switchaudio.sys (ARM64 PortCls WaveRT speaker driver: ADMA -> ADMAIF1 -> I2S1 -> ALC5639)
# from the SwitchAudio sources of the winx project
# (github.com/ruje0504-2/Windows-for-Switch-Drivers, drivers/SwitchAudio, GPL-2.0) and test-signs it.
#
#   drivers/build_audio.sh SWITCHAUDIO_SRC WDK_C SDK_C OUT_DIR
#
# Flags as in their build-arm64.sh. Same tools and test certificate as build_wifi.sh.
set -euo pipefail
SRC="$(cd "$1" && pwd)"; WDK="$(cd "$2" && pwd)"; SDK="$(cd "$3" && pwd)"; mkdir -p "$4"; OUT="$(cd "$4" && pwd)"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
LLVM="${LLVM:-/opt/homebrew/opt/llvm/bin}"
V=10.0.26100.0
I="$WDK/Include/$V"; SI="$SDK/Include/$V"
OBJ="$OUT/obj-audio"; rm -rf "$OBJ"; mkdir -p "$OBJ"

"$LLVM/clang-cl" --target=aarch64-pc-windows-msvc /nologo /c /kernel /GS- /Gy /Zl /O2 /W4 /GR- \
    -Wno-nonportable-include-path -Wno-pragma-pack -Wno-microsoft-anon-tag \
    -Wno-ignored-pragma-intrinsic -Wno-unknown-pragmas -Wno-ignored-attributes \
    -Wno-invalid-token-paste /D_ARM64_ /DARM64 /D_WIN64 /D_KERNEL_MODE \
    /DNTDDI_VERSION=0x0A000008 /D_WIN32_WINNT=0x0A00 /DPOOL_NX_OPTIN=1 \
    "/imsvc$I/km/crt" "/imsvc$I/km" "/imsvc$SI/shared" "/imsvc$I/shared" "/imsvc$I/km/spb/1.0" \
    "/Fo$OBJ/switchaudio.obj" -- "$SRC/src/switchaudio.cpp"

docker run --rm -v "$WDK:/wdk:ro" -v "$OUT:/out" -v "$PROJECT/drivers/test-cert:/cert:ro" switch-wp-drivers bash -c '
set -e
km=/wdk/Lib/10.0.26100.0/km/ARM64
cd /out/obj-audio
lld-link-14 /nologo /driver /subsystem:native,10.0 /machine:arm64 /entry:DriverEntry /nodefaultlib \
    /opt:ref /opt:icf /tsaware:no /timestamp:0 \
    /section:.text,ERP /section:.rdata,RP /section:.data,RWP /section:.pdata,RP /section:INIT,ERD \
    /out:switchaudio-unsigned.sys switchaudio.obj $km/portcls.lib $km/ntoskrnl.lib $km/hal.lib \
    $km/ntstrsafe.lib $km/libcntpr.lib $km/bufferoverflowfastfailk.lib
llvm-objdump-14 -h switchaudio-unsigned.sys | grep -q "\.reloc" || { echo "ERROR: no .reloc section"; exit 1; }
rm -f /out/switchaudio.sys
osslsigncode sign -certs /cert/wifi-chain.crt -key /cert/wifi.key -h sha256 -in switchaudio-unsigned.sys -out /out/switchaudio.sys >/dev/null
'
cp "$PROJECT/drivers/switchaudio/switchaudio.inf" "$OUT/"
echo "Signed ARM64 driver: $OUT/switchaudio.sys"
