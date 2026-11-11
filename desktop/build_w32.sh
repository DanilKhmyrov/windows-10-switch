#!/bin/bash
# Runs inside the switch-wp-drivers container (--device /dev/fuse --cap-add SYS_ADMIN).
# Builds the Windows 10 ARM32 partition image from scratch (12 GiB, starting at 10815 MiB) from
# the 15035 archive and applies all our changes. Windows Setup stays enabled, but
# swagent\setup.cmd runs instead of oobe\windeploy.exe: it calls windeploy itself
# and copies the setup logs to the CRASHDUMP partition (\agent).
#   build_w32.sh archive.7z output_folder
set -euo pipefail
ARCHIVE="$1"; OUT="$2"; HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
cd "$WORK"
7z x -y -o"$WORK" "$ARCHIVE" sources/install.wim > /dev/null
IMAGE="$OUT/w32.img"
rm -f "$IMAGE"
truncate -s 12G "$IMAGE"
# -p: partition start in sectors (10815 MiB), so that the NTFS boot sector is correct.
mkntfs -F -Q -L Windows -p 22149120 -H 255 -S 63 "$IMAGE" > /dev/null
wimapply "$WORK/sources/install.wim" 1 "$IMAGE" 2>&1 | tr '\r' '\n' | grep -vE '^(Extracting|Applying|Creating)' | tail -2
rm -rf "$WORK/sources"

"$HERE/patch_desktop.sh" "$IMAGE"
"$HERE/skip_bcd_step.sh" "$IMAGE"

TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
ntfs-3g "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
cp "$HERE/setup.cmd" "$HERE/copylogs.cmd" "$HERE/boot.cmd" "$MNT/swagent/"
# Setup itself creates the user (unattend.xml); boot.cmd only writes a log.
echo done > "$MNT/swagent/user.done"
CONFIG="$MNT/Windows/System32/config"
cp "$CONFIG/SYSTEM" "$TMP/SYSTEM"
echo "Original SYSTEM\\Setup values:"
hivexget "$TMP/SYSTEM" '\Setup' | grep -E 'SetupType|SystemSetupInProgress|OOBEInProgress|SetupPhase|CmdLine'
cat > "$TMP/setup.reg" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup]
"CmdLine"="C:\\Windows\\System32\\cmd.exe /c C:\\swagent\\setup.cmd"
REG
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/setup.reg"
cp "$TMP/SYSTEM" "$CONFIG/SYSTEM"
cmp "$TMP/SYSTEM" "$CONFIG/SYSTEM"
hivexget "$CONFIG/SYSTEM" '\Setup' CmdLine
sync
echo "DONE: $IMAGE"
