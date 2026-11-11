#!/bin/bash
# Runs inside the switch-wp-drivers container. Builds and signs an ARM32 driver.
#   build.sh <name> <source.c> <output.sys>   EWDK=path to "Windows Kits/10"
#   ENTRY=DriverEntry: driver without WDF; HASH=sha1: different signing hash
set -euo pipefail
NAME="$1"; SRC="$2"; OUT="$3"
I="$EWDK/Include"; L="$EWDK/Lib"; KM="$I/10.0.14393.0"
A="$L/10.0.14393.0/km/arm"; W="$L/wdf/kmdf/arm/1.19"
TMP="$(mktemp -d)"
FLAGS=(--target=thumbv7-windows-msvc -fms-compatibility -fms-extensions -fno-stack-protector
    -fshort-wchar -O2 -nostdinc -D_ARM_ -D_M_ARM=7 -DWIN32 -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00
    -DNTDDI_VERSION=0x0A000002 -D_KERNEL_MODE=1 -DKMDF_VERSION_MAJOR=1 -DKMDF_VERSION_MINOR=19
    -Wno-everything -isystem "$KM/km/crt" -isystem "$KM/km" -isystem "$KM/shared" -isystem "$I/wdf/kmdf/1.19")
# WDM=1: driver without WDF and without the load-config object from the WDK libraries.
if [ "${WDM:-0}" = 1 ]; then
    LIBS=("$A/ntoskrnl.lib" "$A/hal.lib")
    [ "${HID:-0}" = 1 ] && LIBS+=("$A/hidclass.lib")
    [ "${BATT:-0}" = 1 ] && LIBS+=("$A/battc.lib")
else
    LIBS=("$W/WdfDriverEntry.lib" "$W/WdfLdr.lib" "$A/ntoskrnl.lib" "$A/hal.lib" "$A/BufferOverflowFastFailK.lib")
fi
clang "${FLAGS[@]}" -c "$SRC" -o "$TMP/$NAME.obj"
clang --target=thumbv7-windows-msvc -O2 -ffreestanding -fno-stack-protector -c "$(dirname "$0")/compat.c" -o "$TMP/compat.obj"
lld-link /nologo /machine:arm /driver /subsystem:native,10.0 /osversion:10.0 /base:0x10000 /filealign:0x1000 /stack:0x40000,0x1000 /largeaddressaware /tsaware:no /section:.text,erp /section:.rdata,rp /section:.data,rwp /entry:"${ENTRY:-FxDriverEntry}" /nodefaultlib /out:"$TMP/$NAME.sys" \
    "$TMP/$NAME.obj" "$TMP/compat.obj" "${LIBS[@]}"
CERT="$(dirname "$0")/test-cert"
if [ ! -f "$CERT/test.key" ]; then
    mkdir -p "$CERT"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Switch WP Test Driver" \
        -addext "extendedKeyUsage=codeSigning" -keyout "$CERT/test.key" -out "$CERT/test.crt" 2>/dev/null
fi
rm -f "$OUT"
osslsigncode sign -certs "$CERT/test.crt" -key "$CERT/test.key" -h "${HASH:-sha256}" -in "$TMP/$NAME.sys" -out "$OUT"
echo "$OUT"
