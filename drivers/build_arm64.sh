#!/bin/bash
# Runs inside the switch-wp-drivers container (called by build.sh with ARCH=arm64).
# Builds and test-signs an ARM64 WDM driver. Import libraries are generated: every function the
# driver calls is looked up in the export tables of the real ARM64 binaries in REFBIN.
#   EWDK=path to "Windows Kits/10"  REFBIN=folder with ntoskrnl.exe hal.dll battc.sys hidclass.sys
set -euo pipefail
NAME="$1"; SRC="$2"; OUT="$3"
KM="$EWDK/Include/10.0.14393.0"
TMP="$(mktemp -d)"
FLAGS=(--target=aarch64-pc-windows-msvc -fms-compatibility -fms-extensions -fno-stack-protector
    -fshort-wchar -O2 -nostdinc -D_ARM64_ -D_M_ARM64=1 -D_WIN64 -DWIN32 -D_WIN32_WINNT=0x0A00
    -DWINVER=0x0A00 -DNTDDI_VERSION=0x0A000002 -D_KERNEL_MODE=1
    -Wno-everything -isystem "$KM/km/crt" -isystem "$KM/km" -isystem "$KM/shared")
clang "${FLAGS[@]}" -c "$SRC" -o "$TMP/$NAME.obj"
# The kernel always relocates drivers, and it refuses to load an image without a base
# relocation table (STATUS_DRIVER_UNABLE_TO_LOAD). ARM64 code uses PC-relative addressing, so the
# linker may emit no relocations at all: one absolute pointer guarantees a .reloc section.
printf 'void *const switch_reloc_anchor = (void *) &switch_reloc_anchor;\n' > "$TMP/reloc.c"
clang --target=aarch64-pc-windows-msvc -O2 -ffreestanding -fno-stack-protector -c "$TMP/reloc.c" -o "$TMP/reloc.obj"

# Import libraries: one per binary, containing only the symbols this driver needs.
LIBS=()
for bin in ntoskrnl.exe hal.dll battc.sys hidclass.sys; do
    llvm-readobj-14 --coff-exports "$REFBIN/$bin" | sed -n 's/^ *Name: //p' | sort -u > "$TMP/$bin.exports"
done
llvm-nm-14 -u "$TMP/$NAME.obj" | awk '{print $NF}' | sed 's/^__imp_//' | sort -u > "$TMP/needed"
: > "$TMP/missing"
while read -r sym; do
    for bin in ntoskrnl.exe hal.dll battc.sys hidclass.sys; do
        if grep -qx "$sym" "$TMP/$bin.exports"; then echo "$sym" >> "$TMP/$bin.use"; continue 2; fi
    done
    echo "$sym" >> "$TMP/missing"
done < "$TMP/needed"
if [ -s "$TMP/missing" ]; then
    echo "Not exported by any reference binary:"; cat "$TMP/missing"; exit 1
fi
for bin in ntoskrnl.exe hal.dll battc.sys hidclass.sys; do
    [ -f "$TMP/$bin.use" ] || continue
    { echo "LIBRARY $bin"; echo "EXPORTS"; cat "$TMP/$bin.use"; } > "$TMP/$bin.def"
    llvm-dlltool-14 -m arm64 -d "$TMP/$bin.def" -l "$TMP/${bin%.*}.lib"
    LIBS+=("$TMP/${bin%.*}.lib")
done

lld-link /nologo /machine:arm64 /driver /subsystem:native,10.0 /osversion:10.0 /base:0x1c0000000 /tsaware:no \
    /filealign:0x1000 /stack:0x40000,0x1000 /section:.text,erp /section:.rdata,rp /section:.data,rwp /section:.pdata,rp \
    /entry:"${ENTRY:-DriverEntry}" /nodefaultlib /include:switch_reloc_anchor /out:"$TMP/$NAME.sys" \
    "$TMP/$NAME.obj" "$TMP/reloc.obj" "${LIBS[@]}"
CERT="$(dirname "$0")/test-cert"
rm -f "$OUT"
osslsigncode sign -certs "$CERT/test.crt" -key "$CERT/test.key" -h "${HASH:-sha256}" -in "$TMP/$NAME.sys" -out "$OUT"
echo "$OUT"
