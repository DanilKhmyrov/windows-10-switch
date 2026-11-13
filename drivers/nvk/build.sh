#!/bin/bash
# Builds mesa-switch-woa's NVK Vulkan driver for Windows ARM64 (libvulkan_nouveau.dll and its
# ICD manifest), an ARM64 Vulkan loader (vulkan-1.dll from Khronos' Vulkan-Loader) and the
# author's offscreen triangle test (vk-triangle.exe), in the switch-wp-nvk container.
#
#   drivers/nvk/build.sh MESA_SRC WDK_C SDK_C OUT_DIR
#
# MESA_SRC is the mesa-switch-woa checkout; WDK_C and SDK_C are the "c" folders of the
# Microsoft.Windows.WDK.ARM64 / Microsoft.Windows.SDK.CPP 10.0.26100 NuGet packages.
# The container clones Vulkan-Headers and Vulkan-Loader at VULKAN_SDK_TAG and Meson fetches the
# Rust crates NVK needs into MESA_SRC/subprojects (needs network).
set -euo pipefail
MESA="$(cd "$1" && pwd)"; WDK="$(cd "$2" && pwd)"; SDK="$(cd "$3" && pwd)"
mkdir -p "$4"; OUT="$(cd "$4" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
TAG="${VULKAN_SDK_TAG:-vulkan-sdk-1.4.350.0}"

docker run --rm -v "$MESA:/mesa" -v "$WDK:/wdk:ro" -v "$SDK:/sdk:ro" -v "$OUT:/out" \
    -v "$HERE:/nvk:ro" -e TAG="$TAG" -e JOBS="${JOBS:-6}" -e SKIP_ICD="${SKIP_ICD:-0}" switch-wp-nvk bash -c '
set -euo pipefail
git config --global --add safe.directory "*"
# clang-cl for the SDK-compiled KMT bridge: LLVM-MinGW'"'"'s clang in MSVC driver mode.
ln -sf "$(ls /opt/llvm-mingw/bin/clang-[0-9]* | head -1)" /usr/local/bin/clang-cl
# 1. Mesa build-time tools for the build host (mesa_clc, vtn_bindgen2).
if [ ! -x /out/host-tools/bin/mesa_clc ]; then
    rm -rf /out/host-build
    meson setup /out/host-build /mesa --prefix=/out/host-tools -Dbuildtype=release \
        -Dmesa-clc=enabled -Dinstall-mesa-clc=true -Dllvm=enabled -Dshared-llvm=enabled \
        -Dplatforms=[] -Dvulkan-drivers=[] -Dgallium-drivers=[] -Dglx=disabled -Degl=disabled \
        -Dgbm=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dvideo-codecs=[] \
        -Dbuild-tests=false -Dvalgrind=disabled -Dlibunwind=disabled >/out/host-setup.log
    ninja -C /out/host-build -j "$JOBS" install >/out/host-build.log
fi
export PATH=/out/host-tools/bin:$PATH
# 2. NVK Windows ARM64 ICD with the author'"'"'s script (cross file from this folder).
if [ "${SKIP_ICD:-0}" != 1 ]; then
rm -rf /out/icd
python3 /mesa/src/nouveau/vulkan/nvkmd/windows/build_icd.py --mesa /mesa --out /out/icd \
    --cross-file /nvk/windows-arm64.ini --cc aarch64-w64-mingw32-clang --clang-cl clang-cl \
    --sdk-include /sdk/Include/10.0.26100.0 --wdk-include /wdk/Include/10.0.26100.0
fi
# 3. ARM64 Vulkan loader (vulkan-1.dll and its import library).
if [ ! -f /out/loader/install/bin/vulkan-1.dll ]; then
    rm -rf /out/loader; mkdir -p /out/loader
    git clone -q --depth 1 -b "$TAG" https://github.com/KhronosGroup/Vulkan-Headers /out/loader/headers
    git clone -q --depth 1 -b "$TAG" https://github.com/KhronosGroup/Vulkan-Loader /out/loader/src
    cmake -S /out/loader/headers -B /out/loader/hb -G Ninja -DCMAKE_INSTALL_PREFIX=/out/loader/install >/dev/null
    cmake --install /out/loader/hb >/dev/null
    cmake -S /out/loader/src -B /out/loader/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=ARM64 \
        -DCMAKE_C_COMPILER=aarch64-w64-mingw32-clang -DCMAKE_CXX_COMPILER=aarch64-w64-mingw32-clang++ \
        -DCMAKE_RC_COMPILER=aarch64-w64-mingw32-windres -DCMAKE_ASM_COMPILER=aarch64-w64-mingw32-clang \
        -DCMAKE_PREFIX_PATH=/out/loader/install -DCMAKE_INSTALL_PREFIX=/out/loader/install \
        -DUSE_MASM=OFF -DUSE_GAS=OFF -DBUILD_TESTS=OFF >/out/loader-setup.log
    cmake --build /out/loader/build -j "$JOBS" >/out/loader-build.log
    cmake --install /out/loader/build >/dev/null
fi
# 4. The offscreen triangle test (loads the ICD by path, reads the pixels back, --preview shows them).
rm -rf /out/triangle
lib=/out/loader/install/lib/libvulkan-1.dll.a      # MinGW import library of the loader
python3 /mesa/tegra-x1-wddm/tools/build_offscreen_triangle.py --cc aarch64-w64-mingw32-clang \
    --vulkan-include /out/loader/install/include --loader-dll /out/loader/install/bin/vulkan-1.dll \
    --loader-lib "$lib" --out /out/triangle
# NVK'"'"'s Rust code imports LLVM-MinGW'"'"'s libunwind.dll: ship it beside the ICD and the test.
cp /opt/llvm-mingw/aarch64-w64-mingw32/bin/libunwind.dll /out/icd/
cp /opt/llvm-mingw/aarch64-w64-mingw32/bin/libunwind.dll /out/triangle/
ls -la /out/icd/libunwind.dll /out/icd/libvulkan_nouveau.dll /out/icd/nvk_windows_icd.json /out/loader/install/bin/vulkan-1.dll /out/triangle
'
