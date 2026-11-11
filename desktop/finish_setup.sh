#!/bin/bash
# Runs inside a container (--device /dev/fuse --cap-add SYS_ADMIN). After the error "could not update
# the computer's boot configuration" marks the specialize pass as complete
# (Setup\Status\ChildCompletion\setup.exe = 3), so that setup moves on to OOBE.
# The SYSTEM and SECURITY hives must already be recovered by hive_recover.py (*.rec).
#   finish_setup.sh win.img hive_folder
set -euo pipefail
IMAGE="$1"; HIVES="$2"
TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
ntfsfix -d "$IMAGE" > /dev/null
ntfs-3g "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
CONFIG="$MNT/Windows/System32/config"
cp "$HIVES/SYSTEM.rec" "$TMP/SYSTEM"
cat > "$TMP/fix.reg" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\Status\ChildCompletion]
"setup.exe"=dword:00000003
REG
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/fix.reg"
hivexget "$TMP/SYSTEM" '\Setup\Status\ChildCompletion'
cp "$TMP/SYSTEM" "$CONFIG/SYSTEM"; cmp "$TMP/SYSTEM" "$CONFIG/SYSTEM"
cp "$HIVES/SECURITY.rec" "$CONFIG/SECURITY"; cmp "$HIVES/SECURITY.rec" "$CONFIG/SECURITY"
for HIVE in SYSTEM SECURITY; do : > "$CONFIG/$HIVE.LOG1"; : > "$CONFIG/$HIVE.LOG2"; done
sync
echo ok
