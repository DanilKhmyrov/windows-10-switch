#!/bin/bash
# Runs inside a container (--device /dev/fuse --cap-add SYS_ADMIN): puts the image back into
# Windows Setup mode, but runs swagent\setup.cmd instead of oobe\windeploy.exe; it
# calls windeploy itself and copies the logs to CRASHDUMP. The SYSTEM and SECURITY hives must
# already be recovered by hive_recover.py (a folder with SYSTEM.rec and SECURITY.rec).
#   setup_mode.sh win.img hive_folder
set -euo pipefail
IMAGE="$1"; HIVES="$2"; HERE="$(dirname "$0")"
TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
ntfsfix -d "$IMAGE"
ntfs-3g "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
CONFIG="$MNT/Windows/System32/config"

cp "$HIVES/SYSTEM.rec" "$TMP/SYSTEM"; cp "$HIVES/SECURITY.rec" "$TMP/SECURITY"

cat > "$TMP/setup.reg" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup]
"SystemSetupInProgress"=dword:00000001
"OOBEInProgress"=dword:00000001
"SetupType"=dword:00000002
"SetupPhase"=dword:00000004
"CmdLine"="C:\\Windows\\System32\\cmd.exe /c C:\\swagent\\setup.cmd"
REG
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/setup.reg"
hivexget "$TMP/SYSTEM" '\Setup'

for HIVE in SYSTEM SECURITY; do
    cp "$TMP/$HIVE" "$CONFIG/$HIVE"
    cmp "$TMP/$HIVE" "$CONFIG/$HIVE"
    # The logs are already applied: Windows does not replay empty logs.
    : > "$CONFIG/$HIVE.LOG1"; : > "$CONFIG/$HIVE.LOG2"
done
cp "$HERE/setup.cmd" "$HERE/copylogs.cmd" "$MNT/swagent/"
echo done > "$MNT/swagent/user.done"
sync
echo ok
