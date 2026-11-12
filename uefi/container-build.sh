#!/bin/bash
# Runs inside the container. Sources live in the /work volume,
# the result appears in /project/uefi/out.
set -euo pipefail

# EDK2 release close to the last NintendoSwitchPkg commit (March 2021).
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
# cmocka is only needed for EDK2 unit tests, and its server does not serve the required commit.
git submodule status | awk '{print $2}' | grep -v cmocka \
    | xargs git submodule update --init --depth 1

rm -rf NintendoSwitchPkg
git clone -q --depth 1 "$PKG_REPO" NintendoSwitchPkg
# *-a64only.patch patches are for the 64-bit build only: in the 32-bit one they break early boot
# (timer frequency 0 -> UEFI hangs after mark 6).
for patch in /project/patches/*.patch; do
    case "$patch" in *-a64only.patch) [ "${ARCH:-AARCH64}" = ARM ] && continue;; esac
    # *-cleanonly.patch: only for CLEAN=1: screen output in black (#define CLEAN_BOOT in the files).
    case "$patch" in *-cleanonly.patch) [ "${CLEAN:-0}" = 1 ] || continue;; esac
    # *-win11only.patch: only for WIN11=1: UEFI that boots the Windows 11 partition and prepares Wi-Fi.
    case "$patch" in *-win11only.patch) [ "${WIN11:-0}" = 1 ] || continue;; esac
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

# ARCH=ARM builds the 32-bit version, ARCH=AARCH64 (default) the 64-bit one.
ARCH="${ARCH:-AARCH64}"
export WORKSPACE="$PWD" PYTHON_COMMAND=python3 GCC5_AARCH64_PREFIX=aarch64-linux-gnu- GCC5_ARM_PREFIX=arm-linux-gnueabihf-
make -C BaseTools -j"$(nproc)" >/work/basetools.log 2>&1 || { tail -40 /work/basetools.log; exit 1; }

set +u
. ./edksetup.sh BaseTools
set -u
# TARGET=RELEASE: no debug output on screen (clean boot).
TARGET="${TARGET:-DEBUG}"
# Always a clean build: EDK2 does not rebuild modules when only flags change
# (-D CLEAN_BOOT), and variants get mixed.
rm -rf Build/NintendoSwitch-ARM Build/NintendoSwitch-AARCH64

# CLEAN=1 enables the *-cleanonly.patch patch (see above): the build flags stay the same
# as for the normal debug build (a -D CLEAN_BOOT flag via the DSC broke early boot).
build -n "$(nproc)" -a "$ARCH" -b "$TARGET" -t GCC5 -p NintendoSwitchPkg/NintendoSwitch.dsc

mkdir -p /project/uefi/out
if [ "$ARCH" = ARM ]; then OUT=NintendoSwitch-arm; else OUT=NintendoSwitch; fi
[ "$TARGET" = RELEASE ] && OUT="$OUT-release"
[ "${CLEAN:-0}" = 1 ] && OUT="$OUT-clean"
[ "${WIN11:-0}" = 1 ] && OUT="$OUT-win11"
cp Build/NintendoSwitch-"$ARCH"/"$TARGET"_GCC5/FV/*.fd /project/uefi/out/"$OUT".fd
ls -la /project/uefi/out
