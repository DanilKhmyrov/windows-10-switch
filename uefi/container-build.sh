#!/bin/bash
# Выполняется внутри контейнера. Исходники лежат в томе /work,
# готовый файл появляется в /project/uefi/out.
set -euo pipefail

# Релиз EDK2, близкий к последнему коммиту NintendoSwitchPkg (март 2021).
EDK2_COMMIT="${EDK2_COMMIT:-edk2-stable202102}"
PKG_REPO="https://github.com/imbushuo/NintendoSwitchPkg.git"

cd /work
if [ ! -d edk2/.git ]; then
    git init -q edk2
    git -C edk2 remote add origin https://github.com/tianocore/edk2.git
    git -C edk2 fetch -q --depth 1 origin "$EDK2_COMMIT"
    git -C edk2 checkout -q FETCH_HEAD
fi
cd edk2
# cmocka нужен только для unit-тестов EDK2, и его сервер не отдаёт нужный коммит.
git submodule status | awk '{print $2}' | grep -v cmocka \
    | xargs git submodule update --init --depth 1

rm -rf NintendoSwitchPkg
git clone -q --depth 1 "$PKG_REPO" NintendoSwitchPkg
# Патчи *-a64only.patch нужны только 64-битной сборке: в 32-битной они ломают раннюю загрузку
# (частота таймера 0 → UEFI висит после метки 6).
for patch in /project/patches/*.patch; do
    case "$patch" in *-a64only.patch) [ "${ARCH:-AARCH64}" = ARM ] && continue;; esac
    # *-cleanonly.patch — только для CLEAN=1: вывод на экран чёрным (#define CLEAN_BOOT в файлах).
    case "$patch" in *-cleanonly.patch) [ "${CLEAN:-0}" = 1 ] || continue;; esac
    git -C NintendoSwitchPkg apply "$patch"
done

COMMIT="$(git -C NintendoSwitchPkg rev-parse --short=8 HEAD)"
cat > NintendoSwitchPkg/Include/FwReleaseInfo.h <<EOF
#ifndef __SMBIOS_RELEASE_INFO_H__
#define __SMBIOS_RELEASE_INFO_H__
#undef __IMPL_COMMIT_ID__
#define __IMPL_COMMIT_ID__ "$COMMIT"
#undef __RELEASE_DATE__
#define __RELEASE_DATE__ "$(date +%m/%d/%Y)"
#endif
EOF

# ARCH=ARM собирает 32-битную версию, ARCH=AARCH64 (по умолчанию) — 64-битную.
ARCH="${ARCH:-AARCH64}"
export WORKSPACE="$PWD" PYTHON_COMMAND=python3 GCC5_AARCH64_PREFIX=aarch64-linux-gnu- GCC5_ARM_PREFIX=arm-linux-gnueabihf-
make -C BaseTools -j"$(nproc)" >/work/basetools.log 2>&1 || { tail -40 /work/basetools.log; exit 1; }

set +u
. ./edksetup.sh BaseTools
set -u
# TARGET=RELEASE — без отладочного вывода на экран (чистая загрузка).
TARGET="${TARGET:-DEBUG}"
# Сборка всегда с нуля: EDK2 не пересобирает модули, если поменялись только флаги
# (-D CLEAN_BOOT), и варианты смешиваются.
rm -rf Build/NintendoSwitch-ARM Build/NintendoSwitch-AARCH64

# CLEAN=1 включает патч *-cleanonly.patch (см. выше): флаги сборки при этом те же,
# что и у обычной отладочной версии (флаг -D CLEAN_BOOT через DSC ломал раннюю загрузку).
build -n "$(nproc)" -a "$ARCH" -b "$TARGET" -t GCC5 -p NintendoSwitchPkg/NintendoSwitch.dsc

mkdir -p /project/uefi/out
if [ "$ARCH" = ARM ]; then OUT=NintendoSwitch-arm; else OUT=NintendoSwitch; fi
[ "$TARGET" = RELEASE ] && OUT="$OUT-release"
[ "${CLEAN:-0}" = 1 ] && OUT="$OUT-clean"
cp Build/NintendoSwitch-"$ARCH"/"$TARGET"_GCC5/FV/*.fd /project/uefi/out/"$OUT".fd
ls -la /project/uefi/out
