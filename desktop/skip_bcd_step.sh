#!/bin/bash
# Внутри контейнера (--device /dev/fuse --cap-add SYS_ADMIN). Убирает из этапа специализации
# шаг Sysprep_Specialize_Bcd: он не может открыть хранилище настроек загрузки без
# постоянных переменных UEFI, а настройки загрузки мы готовим сами.   skip_bcd_step.sh w32.img
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
    raise SystemExit(f"Ожидался один шаг SpBcd, найдено {count}")
open(path, "w", encoding="utf-8", newline="").write(new)
print("removed SpBcd step")
PY
grep -c 'Sysprep_Specialize_Bcd' "$FILE" || true
sync
echo ok
