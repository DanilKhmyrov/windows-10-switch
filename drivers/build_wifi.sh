#!/bin/bash
# Builds switchwifi.sys (ARM64 KMDF/NetAdapterCx/WiFiCx driver for the BCM4356) from the
# SwitchWifi sources of the winx project (github.com/ruje0504-2/Windows-for-Switch-Drivers,
# drivers/SwitchWifi, GPL-2.0) and test-signs it.
#
#   drivers/build_wifi.sh SWITCHWIFI_SRC WDK_C SDK_C OUT_DIR
#
# SWITCHWIFI_SRC  checkout of drivers/SwitchWifi (its tools/kmdf_support.c sits two levels up)
# WDK_C, SDK_C    the "c" folder of the unpacked NuGet packages Microsoft.Windows.WDK.ARM64 and
#                 Microsoft.Windows.SDK.CPP, version 10.0.26100
# Needs Homebrew LLVM (clang-cl, llvm-lib) and the switch-wp-drivers Docker image
# (lld-link, osslsigncode). Signs with drivers/test-cert/wifi.{crt,key}: valid from 2015,
# because the console's clock starts in 2022 after every boot.
set -euo pipefail
SRC="$(cd "$1" && pwd)"; WDK="$(cd "$2" && pwd)"; SDK="$(cd "$3" && pwd)"; mkdir -p "$4"; OUT="$(cd "$4" && pwd)"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
LLVM="${LLVM:-/opt/homebrew/opt/llvm/bin}"
V=10.0.26100.0
I="$WDK/Include/$V"; SI="$SDK/Include/$V"
OBJ="$OUT/obj"; rm -rf "$OBJ"; mkdir -p "$OBJ"

FLAGS=(--target=aarch64-pc-windows-msvc /c /kernel /GS- /Zl /O2 /W4 /WX
    -Wno-unused-parameter -Wno-microsoft-anon-tag -Wno-ignored-pragma-intrinsic -Wno-pragma-pack
    -Wno-invalid-token-paste -Wno-unknown-pragmas -Wno-ignored-attributes -Wno-nonportable-include-path
    /D_ARM64_ /D_WIN64 /D_KERNEL_MODE /DKMDF_VERSION_MAJOR=1 /DKMDF_VERSION_MINOR=33
    /DNTDDI_VERSION=0x0A00000C /D_WIN32_WINNT=0x0A00
    "/imsvc$I/km/crt" "/imsvc$I/km" "/imsvc$SI/shared" "/imsvc$I/shared" "/imsvc$WDK/Include/wdf/kmdf/1.33"
    "/imsvc$SI/shared/netcx/shared/1.0" "/imsvc$I/km/wificx/1.0" "/imsvc$I/km/wlan/2.0"
    "/imsvc$I/km/netcx/kmdf/adapter/2.2")
SOURCES=(core/msgbuf_data.c core/msgbuf_ring.c core/msgbuf_control.c core/phy_rates.c core/rx_metadata.c
    core/receive_filter.c core/pci_intx.c core/station_frame.c core/station_security.c
    windows/transport.c windows/resources.c windows/chip.c windows/shared.c windows/control.c
    windows/lifecycle.c windows/firmware.c windows/capabilities.c windows/requests.c windows/tlv_memory.cpp
    windows/scan.c windows/scan_firmware.c windows/report.c windows/station_filter.c windows/station_data.c
    windows/adapter.c windows/device.c windows/join.c windows/join_firmware.c windows/station_keys.c)
for s in "${SOURCES[@]}"; do
    extra=(); [[ "$s" == *.cpp ]] && extra=(/GR-)
    "$LLVM/clang-cl" "${FLAGS[@]}" ${extra[@]+"${extra[@]}"} "/Fo$OBJ/$(basename "${s%.*}").obj" -- "$SRC/$s"
done
"$LLVM/llvm-lib" /nologo "/out:$OBJ/SwitchWifiTransport.lib" "$OBJ"/*.obj
"$LLVM/clang-cl" --target=aarch64-pc-windows-msvc /c /GS- /Zl "/Fo$OBJ/kmdf_support.o" -- "$SRC/../../tools/kmdf_support.c"

docker run --rm -v "$WDK:/wdk:ro" -v "$OUT:/out" -v "$PROJECT/drivers/test-cert:/cert:ro" switch-wp-drivers bash -c '
set -e
km=/wdk/Lib/10.0.26100.0/km/ARM64; wdf=/wdk/Lib/wdf/kmdf/ARM64/1.33
cd /out/obj
lld-link-14 /nologo /driver /subsystem:native,10.0 /machine:arm64 /entry:FxDriverEntry /nodefaultlib \
    /opt:ref /opt:icf /section:.text,ERP /section:.rdata,RP /section:.data,RWP /section:.pdata,RP \
    /section:INIT,ERD /tsaware:no /timestamp:0 /out:switchwifi-unsigned.sys \
    kmdf_support.o SwitchWifiTransport.lib $wdf/wdfdriverentry.lib $wdf/wdfldr.lib \
    $km/wificx/1.0/wificxstub.lib $km/netcx/kmdf/adapter/2.2/netadaptercxstub.lib \
    $km/wlan/2.0/WificxTLVGenParse.lib $km/ndis.lib $km/bufferoverflowfastfailk.lib $km/libcntpr.lib \
    $km/ntoskrnl.lib $km/hal.lib
llvm-objdump-14 -h switchwifi-unsigned.sys | grep -q "\.reloc" || { echo "ERROR: no .reloc section"; exit 1; }
rm -f /out/switchwifi.sys
osslsigncode sign -certs /cert/wifi.crt -key /cert/wifi.key -h sha256 -in switchwifi-unsigned.sys -out /out/switchwifi.sys >/dev/null
'
cp "$PROJECT/drivers/switchwifi/switchwifi.inf" "$OUT/"
echo "Signed ARM64 driver: $OUT/switchwifi.sys"
