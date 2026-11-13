#!/bin/bash
# Builds the desktop (tgd3d) components of mesa-switch-woa's tgd3d-vulkan branch in the
# switch-wp-nvk container, with the author's scripts:
#   kmd/   WDDM display build of the GPU driver with gated native submission
#          (tools/build.py --display --native-test-version N), unsigned
#   icd/   the matching NVK Vulkan ICD (build_icd.py)
#   umd/   tgd3d, the Direct3D 10/11 user-mode driver on Vulkan (build_tgd3d.py, CPU-sync
#          control mode as in the author's tested packages)
#
#   drivers/nvk/build_desktop.sh TOOLCHAIN_DIR MESA_TGD3D OUT_DIR [N]
#
# TOOLCHAIN_DIR is ~/switch-toolchain (WDK/SDK NuGet folders, NVIDIA firmware); it is mounted at
# the same path so the git worktree MESA_TGD3D keeps working inside the container.
set -euo pipefail
T="$(cd "$1" && pwd)"; MESA="$(cd "$2" && pwd)"; mkdir -p "$3"; OUT="$(cd "$3" && pwd)"
N="${4:-201}"
HERE="$(cd "$(dirname "$0")" && pwd)"
docker run --rm -v "$T:$T" -v "$OUT:/out" -v "$HERE:/nvk:ro" -e T="$T" -e MESA="$MESA" -e N="$N" \
    -e JOBS="${JOBS:-6}" switch-wp-nvk bash -c '
set -euo pipefail
git config --global --add safe.directory "*"
ln -sf "$(ls /opt/llvm-mingw/bin/clang-[0-9]* | head -1)" /usr/local/bin/clang-cl
W=$T/wdk26100/pkg/c/Include/10.0.26100.0; S=$T/sdk26100/pkg/c/Include/10.0.26100.0
FW=$T/nvidia-l4t-firmware/x/lib/firmware/tegra21x
# Host tools for this tree.
if [ ! -x /out/host-tools/bin/mesa_clc ]; then
    rm -rf /out/host-build
    meson setup /out/host-build "$MESA" --prefix=/out/host-tools -Dbuildtype=release \
        -Dmesa-clc=enabled -Dinstall-mesa-clc=true -Dllvm=enabled -Dshared-llvm=enabled \
        -Dplatforms=[] -Dvulkan-drivers=[] -Dgallium-drivers=[] -Dglx=disabled -Degl=disabled \
        -Dgbm=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dvideo-codecs=[] \
        -Dbuild-tests=false -Dvalgrind=disabled -Dlibunwind=disabled >/out/host-setup.log
    ninja -C /out/host-build -j "$JOBS" install >/out/host-build.log
fi
export PATH=/out/host-tools/bin:$PATH
if [ "${SKIP_KMD:-0}" != 1 ]; then
    rm -rf /out/kmd
    python3 "$MESA/tegra-x1-wddm/tools/build.py" --mesa "$MESA" --wdk-include "$W" --sdk-include "$S" \
        --out /out/kmd --cc clang --clang-cl clang-cl --lib llvm-lib --link lld-link \
        --dlltool llvm-dlltool --display --native-test-version "$N" --gr-firmware "$FW" \
        --acr-firmware "$FW" >/out/kmd.log 2>&1 || { tail -30 /out/kmd.log; exit 1; }
fi
rm -rf /out/icd
python3 "$MESA/src/nouveau/vulkan/nvkmd/windows/build_icd.py" --mesa "$MESA" --out /out/icd \
    --cross-file /nvk/windows-arm64.ini --cc aarch64-w64-mingw32-clang --clang-cl clang-cl \
    --sdk-include "$S" --wdk-include "$W" >/out/icd.log 2>&1 || { grep -E "error|FAILED" /out/icd.log | grep -v rustfmt | head -20; exit 1; }
cp /opt/llvm-mingw/aarch64-w64-mingw32/bin/libunwind.dll /out/icd/
rm -rf /out/umd
python3 "$MESA/tegra-x1-wddm/tools/build_tgd3d.py" --out /out/umd --cross-file /nvk/windows-arm64.ini \
    --sdk-include "$S" --wdk-include "$W" --cpu-sync-control >/out/umd.log 2>&1 || { grep -E "error|FAILED" /out/umd.log | head -20; exit 1; }
ls -la /out/kmd/kit/tegragpurender /out/icd/libvulkan_nouveau.dll /out/umd/TegraGpuD3DVk.dll
'
