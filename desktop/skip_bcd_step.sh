#!/bin/bash
# Runs inside a container (--device /dev/fuse --cap-add SYS_ADMIN). Removes the
# Sysprep_Specialize_Bcd step from the specialize pass: it cannot open the BCD store without
# persistent UEFI variables, and we prepare the boot configuration ourselves.   skip_bcd_step.sh w32.img
set -euo pipefail
IMAGE="$1"
TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
ntfs-3g "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
FILE="$MNT/Windows/System32/Sysprep/ActionFiles/Specialize.xml"
python3 -I - "$FILE" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8", newline="").read()
pattern = r'<imaging exclude="">(?:(?!</imaging>).)*?Sysprep_Specialize_Bcd.*?</imaging>'
new, count = re.subn(pattern, "", text, flags=re.S)
if count != 1:
    raise SystemExit(f"Expected one SpBcd step, found {count}")
open(path, "w", encoding="utf-8", newline="").write(new)
print("removed SpBcd step")
PY
grep -c 'Sysprep_Specialize_Bcd' "$FILE" || true
sync
echo ok
