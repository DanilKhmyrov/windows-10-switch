#!/bin/bash
# Builds tegragpurender.sys, the experimental GM20B MCDM kernel driver of the mesa-switch-woa
# project (github.com/ruje0504-2/mesa-switch-woa, tegra-x1-wddm/, MIT and GPL-2.0 parts), with the
# same sources and flags as its tools/build.py (render package), and test-signs it.
#
#   drivers/build_gpu.sh MESA_SRC WDK_C SDK_C FIRMWARE_DIR OUT_DIR
#
# MESA_SRC      checkout of mesa-switch-woa
# WDK_C, SDK_C  the "c" folder of the NuGet packages Microsoft.Windows.WDK.ARM64 and
#               Microsoft.Windows.SDK.CPP, version 10.0.26100
# FIRMWARE_DIR  NVIDIA tegra21x GPU firmware (NETB_img.bin, fecs.bin, gpccs.bin,
#               nv_acr_ucode_prod.bin, pmu_bl.bin, gpmu_ucode_image.bin, gpmu_ucode_desc.bin,
#               pmu_sig.bin, fecs_sig.bin) from NVIDIA's nvidia-l4t-firmware 32.7.6 package.
#               Not redistributable; copied into the output package only.
# The project's own host tests (tools/build.py) need newer tools than our container has for the
# kernel part, so they are run separately; this script only compiles (Homebrew clang-cl) and
# links (lld-link in the switch-wp-drivers container), as build_wifi.sh does.
set -euo pipefail
MESA="$(cd "$1" && pwd)"; WDK="$(cd "$2" && pwd)"; SDK="$(cd "$3" && pwd)"; FW="$(cd "$4" && pwd)"
mkdir -p "$5"; OUT="$(cd "$5" && pwd)"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
LLVM="${LLVM:-/opt/homebrew/opt/llvm/bin}"
V=10.0.26100.0
I="$WDK/Include/$V"; SI="$SDK/Include/$V"
R="$MESA/tegra-x1-wddm"
OBJ="$OUT/obj-gpu"; rm -rf "$OBJ"; mkdir -p "$OBJ"
PKG="$OUT/tegragpurender"; rm -rf "$PKG"; mkdir -p "$PKG"

FLAGS=(--target=aarch64-pc-windows-msvc /nologo /c /kernel /GS- /Gy /Zl /O2 /W4 /WX /std:c11
    /clang:-ffreestanding -Wno-microsoft-anon-tag -Wno-pragma-pack -Wno-ignored-pragma-intrinsic
    -Wno-nonportable-include-path /D_ARM64_ /DARM64 /D_WIN64 /D_WIN32_WINNT=0x0A00
    /DNTDDI_VERSION=0x0A00000C /DNDEBUG /DDXGKDDI_INTERFACE_VERSION=DXGKDDI_INTERFACE_VERSION_WDDM2_6
    "/I$MESA/src/nouveau/vulkan/nvkmd/windows" "/I$MESA/src" "/I$MESA/src/nouveau/headers"
    "/I$MESA/src/nouveau/headers/nvidia/classes"
    "/imsvc$I/km/crt" "/imsvc$I/km" "/imsvc$I/shared" "/imsvc$SI/shared" "/imsvc$SI/ucrt")

SOURCES=(core/gm20b_mmu.c core/report.c core/gpfifo.c core/fault.c core/execute.c core/submission.c
    core/channel.c core/command_stream.c core/copy_stream.c core/paging_dma.c platform/t214_mmu.c
    platform/t214_frontend.c platform/t214_gr.c platform/t214_acr.c platform/t214_pmu.c
    core/gr_firmware.c core/acr_firmware.c core/gr_image.c core/gr_submit.c core/gr_clear.c
    core/gr_draw.c platform/t214_gr_context.c platform/t214_interrupt.c
    ../src/nouveau/horizon/nouveau_horizon_gm20b.c
    platform/t214_power.c platform/t214_clock.c platform/t214_dc.c windows/resources.c
    windows/panel.c windows/panel_vidpn.c windows/panel_scanout.c windows/private_memory.c
    windows/paging.c windows/table_segment.c windows/root_table.c windows/paging_buffer.c
    windows/paging_dispatch.c windows/paging_submit.c windows/context.c windows/internal_va.c
    windows/submit_worker.c windows/graphics.c windows/hardware.c windows/work_queue.c
    windows/allocation.c windows/query.c windows/adapter.c windows/submit_ddi.c windows/present.c
    windows/command_snapshot.c windows/recovery.c windows/diagnostic_events.c windows/platform_io.c
    windows/worker.c windows/platform_adapter.c windows/gr_firmware_io.c windows/reset_backend.c
    windows/adapter_reset.c)
for s in "${SOURCES[@]}"; do
    n="$(basename "$s" .c)"
    "$LLVM/clang-cl" "${FLAGS[@]}" "/Fo$OBJ/$n.obj" -- "$R/$s"
done
"$LLVM/clang-cl" "${FLAGS[@]}" /GS "/Fo$OBJ/render_miniport.obj" -- "$R/windows/render_miniport.c"
"$LLVM/clang-cl" --target=aarch64-pc-windows-msvc /nologo /c /O2 /GS- /Zl /W4 /WX /std:c11 \
    -Wno-nonportable-include-path /D_ARM64_ "/imsvc$SI/um" "/imsvc$I/km/crt" "/imsvc$I/shared" \
    "/imsvc$SI/shared" "/imsvc$SI/ucrt" "/Fo$OBJ/no_d3d.obj" -- "$R/windows/no_d3d.c"

docker run --rm --network none -v "$WDK:/wdk:ro" -v "$OUT:/out" -v "$PROJECT/drivers/test-cert:/cert:ro" \
    switch-wp-drivers bash -c '
set -e
km=/wdk/Lib/10.0.26100.0/km/ARM64
cd /out/obj-gpu
objs=$(ls *.obj | grep -v -e "^render_miniport.obj$" -e "^no_d3d.obj$")
llvm-lib-14 /nologo /machine:arm64 /out:TegraGpuCore.lib $objs
lld-link-14 /nologo /driver /subsystem:native,10.0 /machine:arm64 /entry:GsDriverEntry \
    /include:_load_config_used /nodefaultlib /opt:ref /tsaware:no /section:.text,ERP \
    /section:.rdata,RP /section:.data,RWP /section:.pdata,RP /section:INIT,ERD /timestamp:0 \
    /out:tegragpurender-unsigned.sys render_miniport.obj TegraGpuCore.lib \
    $km/displib.lib $km/ntoskrnl.lib $km/hal.lib $km/bufferoverflowfastfailk.lib $km/libcntpr.lib
lld-link-14 /nologo /dll /noentry /machine:arm64 /nodefaultlib /opt:ref /timestamp:0 \
    /out:/out/tegragpurender/tegragpuno3d.dll /implib:tegragpuno3d.lib no_d3d.obj
llvm-objdump-14 -h tegragpurender-unsigned.sys | grep -q "\.reloc" || { echo "ERROR: no .reloc section"; exit 1; }
osslsigncode sign -certs /cert/wifi-chain.crt -key /cert/wifi.key -h sha256 \
    -in tegragpurender-unsigned.sys -out /out/tegragpurender/tegragpurender.sys >/dev/null
'
# DriverVer back-dated as for Wi-Fi: Inf2Cat on the console refuses a date in its future.
sed 's|^DriverVer=[0-9/]*,|DriverVer=05/02/2022,|' "$R/windows/tegragpurender.inf" > "$PKG/tegragpurender.inf"
for f in NETB_img.bin fecs.bin gpccs.bin nv_acr_ucode_prod.bin pmu_bl.bin gpmu_ucode_image.bin \
        gpmu_ucode_desc.bin pmu_sig.bin fecs_sig.bin; do
    cp "$FW/$f" "$PKG/"
done
echo "Signed ARM64 MCDM package: $PKG"
