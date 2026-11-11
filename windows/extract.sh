#!/bin/bash
# Достаёт загрузочные файлы из ISO с Windows 10 IoT Core.
#   ./windows/extract.sh путь/к/образу.iso
# Результат: windows/out/EFI/...
set -euo pipefail

ISO="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
HERE="$(cd "$(dirname "$0")" && pwd)"

docker build -q -t switch-wp-windows -f "$HERE/Dockerfile" "$HERE"
docker run --rm \
    -v "$ISO:/input.iso:ro" \
    -v "$HERE:/windows" \
    switch-wp-windows bash -c '
set -euo pipefail
cd /tmp
7z x -y -oiso /input.iso > /dev/null
MSI="$(find iso -iname "*.msi" | head -1)"
echo "MSI: $MSI"
msiextract -C msi "$MSI" > /dev/null
FFU="$(find msi -iname "flash.ffu" | head -1)"
echo "FFU: $FFU"
python3 /windows/ffu_extract.py "$FFU" EFIESP efiesp.img
rm -rf /windows/out
mkdir -p /windows/out
mcopy -s -n -i efiesp.img ::/EFI /windows/out/
find /windows/out -iname "*.efi" -o -iname "BCD*"
'
