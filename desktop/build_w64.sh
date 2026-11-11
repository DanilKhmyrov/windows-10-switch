#!/bin/bash
# Runs inside the switch-wp-drivers container (--device /dev/fuse --cap-add SYS_ADMIN).
# Builds the Windows 10 ARM64 partition image from an ESD/WIM and everything for the small FAT
# boot partition:
#   <folder>/w64.img  NTFS image for the Windows partition (write it with setup_card.py);
#   <folder>/boot/    files for the FAT boot partition: boot manager, BCD, \agent\w64.cmd.
# Applied to the image: answer file (user Player, autologon), the swagent service that runs
# \agent\w64.cmd from the boot partition on every boot, sdbus/sdstor as boot-start drivers,
# skipping the Sysprep BCD step, and a setup wrapper that copies setup logs to \agent\a64.
#   build_w64.sh image.esd index folder DISK_SIGNATURE WINDOWS_START_MiB BOOT_START_MiB [SIZE_MiB]
# setup_card.py prints the disk signature and partition offsets of your card.
set -euo pipefail
ESD="$1"; INDEX="$2"; OUT="$3"; SIGNATURE="$4"; START_MIB="$5"; BOOT_MIB="$6"; SIZE_MIB="${7:-24576}"
HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="$OUT/w64.img"
rm -f "$IMAGE"
truncate -s "${SIZE_MIB}M" "$IMAGE"
mkntfs -F -Q -L Windows64 -p $((START_MIB * 2048)) -H 255 -S 63 "$IMAGE" > /dev/null
# COMPACT=XPRESS4K applies the image WOF-compressed (CompactOS): Windows 11 Pro is about 22 GB
# unpacked and roughly half of that compressed.
wimapply "$ESD" "$INDEX" "$IMAGE" ${COMPACT:+--compact="$COMPACT"} 2>&1 | tr '\r' '\n' | grep -vE '^(Extracting|Applying|Creating)' | tail -2

TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
ntfs-3g "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
mkdir -p "$MNT/Windows/Panther" "$MNT/swagent"
cp "$HERE/unattend64.xml" "$MNT/Windows/Panther/unattend.xml"
cp "$HERE/boot64.cmd" "$MNT/swagent/boot.cmd"
cp "$HERE/setup64.cmd" "$MNT/swagent/setup.cmd"
cp "$HERE/findagent64.cmd" "$MNT/swagent/findagent.cmd"
cp "$HERE/copylogs.cmd" "$MNT/swagent/copylogs.cmd"

# Specialize steps that cannot work here (see below).
python3 - "$MNT/Windows/System32/Sysprep/ActionFiles/Specialize.xml" <<'PY'
import re, sys
p = sys.argv[1]
raw = open(p, "rb").read()
enc = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
t = raw.decode(enc)
# Sysprep-SpBcd needs persistent UEFI variables. TerminalServices-ClientActiveXCore
# (tssysprep.dll, RdpSysPrepRestoreOnline) fails on Windows 11 with error 19 and stops setup
# with "Windows could not configure Windows to run on this computer's hardware".
for component in ("Microsoft-Windows-Sysprep-SpBcd", "Microsoft-Windows-TerminalServices-ClientActiveXCore"):
    t, n = re.subn(r"<imaging[^>]*>(?:(?!</imaging>).)*" + component + r"(?:(?!</imaging>).)*</imaging>\s*", "", t, flags=re.S)
    if n == 0 and component.endswith("SpBcd"):
        raise SystemExit("SpBcd step not found")
    print(f"removed {component} steps: {n}")
open(p, "wb").write(t.encode(enc))
PY

CONFIG="$MNT/Windows/System32/config"
cp "$CONFIG/SYSTEM" "$TMP/SYSTEM"
echo "Original SYSTEM\\Setup:"
hivexget "$TMP/SYSTEM" '\Setup' | grep -E 'SetupType|SystemSetupInProgress|OOBEInProgress|SetupPhase|CmdLine' || true
# sdbus/sdstor must start with the kernel, or the boot volume is missing
# (INACCESSIBLE_BOOT_DEVICE).
cat > "$TMP/system.reg" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\swagent]
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000000
"ObjectName"="LocalSystem"
"ImagePath"=str(2):"C:\\Windows\\System32\\cmd.exe /c start /b C:\\Windows\\System32\\cmd.exe /c C:\\swagent\\boot.cmd"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\CrashControl]
"DisplayParameters"=dword:00000001
"AutoReboot"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\Setup]
"CmdLine"="C:\\Windows\\System32\\cmd.exe /c C:\\swagent\\setup.cmd"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\sdbus]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\sdstor]
"Start"=dword:00000000
REG
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/system.reg"
cp "$TMP/SYSTEM" "$CONFIG/SYSTEM"; cmp "$TMP/SYSTEM" "$CONFIG/SYSTEM"
hivexget "$CONFIG/SYSTEM" '\Setup' CmdLine

# Do not edit the SOFTWARE hive or the default user hive here: after a hivex merge into SOFTWARE,
# Windows 11 setup could not write to it (errors 13 and 19 in the specialize pass). OneDrive is
# disabled later by w64.cmd; the answer file already skips the network/account screens.

# Boot partition contents: ARM64 boot manager, a BCD for this card, the agent script.
ESP="$OUT/boot"
rm -rf "$ESP"; mkdir -p "$ESP/EFI/Boot" "$ESP/EFI/Microsoft/Boot"
cp -r "$MNT/Windows/Boot/EFI/." "$ESP/EFI/Microsoft/Boot/"
cp -r "$MNT/Windows/Boot/Fonts" "$ESP/EFI/Microsoft/Boot/Fonts"
cp "$MNT/Windows/Boot/EFI/bootmgfw.efi" "$ESP/EFI/Boot/bootaa64.efi"
"$HERE/make_bcd64.sh" "$MNT/Windows/System32/config/BCD-Template" "$ESP/EFI/Microsoft/Boot/BCD" \
    "$SIGNATURE" "$START_MIB" "$BOOT_MIB"
mkdir -p "$ESP/agent"
cp "$HERE/w64.cmd" "$ESP/agent/w64.cmd"
# ARM64 touch and battery drivers, if built (drivers/build.sh with ARCH=arm64); w64.cmd installs them.
if [ -f "$HERE/../drivers/out/arm64/swhid.sys" ]; then
    mkdir -p "$ESP/agent/arm64"
    cp "$HERE/../drivers/out/arm64/swhid.sys" "$HERE/../drivers/out/arm64/swbatt.sys" "$ESP/agent/arm64/"
fi
du -sh "$ESP"
echo "$SIGNATURE $START_MIB $BOOT_MIB $SIZE_MIB" > "$OUT/card.txt"
sync
echo "DONE: $IMAGE"
