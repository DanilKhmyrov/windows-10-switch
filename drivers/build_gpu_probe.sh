#!/bin/bash
# Builds the KMDF diagnostic GPU driver of mesa-switch-woa (tegragpuprobe.sys, windows/probe.c)
# and its check tool (performance-check.exe), as that project's tools/build.py --probe and
# integration/switch-lite/performance-check/build.sh do. The probe binds to the same ACPI device
# as the render driver (SWOA0F01, GPU Test loader only) and runs fixed workloads on request:
#   performance-check.exe --gpu-json --gpu-clear-729   blue clear, pixels read back and checked
#   performance-check.exe --gpu-json --gpu-draw-729    clear, then a red triangle from a NAK shader
# The PMIC requests go through swbatt's \Device\SwitchBacklight bridge (GPU rail only).
#
#   drivers/build_gpu_probe.sh MESA_SRC WDK_C SDK_C FIRMWARE_DIR OUT_DIR
#
# Same arguments as build_gpu.sh. Firmware is copied into the output package only.
set -euo pipefail
MESA="$(cd "$1" && pwd)"; WDK="$(cd "$2" && pwd)"; SDK="$(cd "$3" && pwd)"; FW="$(cd "$4" && pwd)"
mkdir -p "$5"; OUT="$(cd "$5" && pwd)"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
LLVM="${LLVM:-/opt/homebrew/opt/llvm/bin}"
V=10.0.26100.0
I="$WDK/Include/$V"; SI="$SDK/Include/$V"
R="$MESA/tegra-x1-wddm"
OBJ="$OUT/obj-probe"; rm -rf "$OBJ"; mkdir -p "$OBJ"
PKG="$OUT/tegragpuprobe"; rm -rf "$PKG"; mkdir -p "$PKG"
TOOL="$OUT/performance-check"; rm -rf "$TOOL"; mkdir -p "$TOOL"

FLAGS=(--target=aarch64-pc-windows-msvc /nologo /c /kernel /GS- /Gy /Zl /O2 /W4 /WX /std:c11
    /clang:-ffreestanding -Wno-microsoft-anon-tag -Wno-pragma-pack -Wno-ignored-pragma-intrinsic
    -Wno-nonportable-include-path /D_ARM64_ /DARM64 /D_WIN64 /D_WIN32_WINNT=0x0A00
    /DNTDDI_VERSION=0x0A00000C /DNDEBUG /DDXGKDDI_INTERFACE_VERSION=DXGKDDI_INTERFACE_VERSION_WDDM2_6
    "/I$MESA/src/nouveau/vulkan/nvkmd/windows" "/I$MESA/src" "/I$MESA/src/nouveau/headers"
    "/I$MESA/src/nouveau/headers/nvidia/classes"
    "/imsvc$I/km/crt" "/imsvc$I/km" "/imsvc$I/shared" "/imsvc$SI/shared" "/imsvc$SI/ucrt")
KFLAGS=("${FLAGS[@]}" /DKMDF_VERSION_MAJOR=1 /DKMDF_VERSION_MINOR=15 /DPOOL_NX_OPTIN=1
    /DSWITCH_LITE_GPU=1 -Wno-unused-parameter -Wno-invalid-token-paste -Wno-unknown-pragmas
    -Wno-ignored-attributes "/I$R" "/imsvc$WDK/Include/wdf/kmdf/1.15" "/imsvc$I/km/spb/1.0")

# The same core and Windows sources as the render driver (build_gpu.sh), as one library.
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
mkdir -p "$OBJ/core"
for s in "${SOURCES[@]}"; do
    "$LLVM/clang-cl" "${FLAGS[@]}" "/Fo$OBJ/core/$(basename "$s" .c).obj" -- "$R/$s"
done
"$LLVM/clang-cl" "${KFLAGS[@]}" "/Fo$OBJ/kmdf_support.obj" -- "$R/tools/kmdf_support.c"
"$LLVM/clang-cl" "${KFLAGS[@]}" "/Fo$OBJ/diagnostic_backend.obj" -- "$R/windows/diagnostic_backend.c"
"$LLVM/clang-cl" "${KFLAGS[@]}" "/Fo$OBJ/tegragpuprobe.obj" -- "$R/windows/probe.c"

# Check tool: no C runtime (entry "start"), Windows SDK headers instead of a MinGW sysroot.
PC="$R/integration/switch-lite/performance-check"
"$LLVM/clang-cl" --target=aarch64-pc-windows-msvc /nologo /c /O2 /GS- /Zl /W3 \
    -Wno-nonportable-include-path -Wno-missing-field-initializers /D_ARM64_ \
    "/I$R" "/I$PC" "/imsvc$SI/um" "/imsvc$SI/shared" "/imsvc$I/km/crt" \
    "/Fo$OBJ/performance-check.obj" -- "$PC/performance-check.c"
python3 - "$OBJ" <<'PY'
import sys
from pathlib import Path
libs = {
 'msvcrt': 'memcpy memset',
 'kernel32': 'CompareStringOrdinal ExitProcess GetModuleHandleW lstrlenW lstrcmpW CreateFileW DeviceIoControl CloseHandle GetLastError CreateThread GetModuleFileNameW GetCommandLineW GetStdHandle WriteFile LocalFree MulDiv FlushFileBuffers',
 'user32': 'wsprintfA wsprintfW GetClientRect ScreenToClient GetPointerInfo InvalidateRect BeginPaint FillRect EndPaint DrawTextW DefWindowProcW KillTimer PostQuitMessage LoadCursorW RegisterClassW GetSystemMetrics CreateWindowExW SetTimer UpdateWindow GetMessageW TranslateMessage DispatchMessageW SendMessageW EnableWindow PostMessageW DestroyWindow MoveWindow',
 'gdi32': 'TextOutW GetStockObject SetBkMode SelectObject SetTextColor SetDCBrushColor Ellipse CreateFontW DeleteObject SetMapMode SetWindowExtEx SetViewportExtEx',
 'shell32': 'ShellExecuteW CommandLineToArgvW',
 'advapi32': 'RegOpenKeyExW RegQueryValueExW RegCloseKey',
 'setupapi': 'SetupDiGetClassDevsW SetupDiEnumDeviceInfo SetupDiGetDeviceInstanceIdW SetupDiDestroyDeviceInfoList',
 'cfgmgr32': 'CM_Get_DevNode_Status'}
for name, symbols in libs.items():
    Path(sys.argv[1], name + '.def').write_text('LIBRARY ' + name + '.dll\nEXPORTS\n' + '\n'.join(symbols.split()) + '\n')
PY

docker run --rm --network none -v "$WDK:/wdk:ro" -v "$OUT:/out" -v "$PROJECT/drivers/test-cert:/cert:ro" \
    switch-wp-drivers bash -c '
set -e
km=/wdk/Lib/10.0.26100.0/km/ARM64
wdf=/wdk/Lib/wdf/kmdf/ARM64/1.15
cd /out/obj-probe
llvm-lib-14 /nologo /machine:arm64 /out:TegraGpuCore.lib core/*.obj
lld-link-14 /nologo /driver /subsystem:native,10.0 /machine:arm64 /entry:FxDriverEntry \
    /nodefaultlib /opt:ref /opt:icf /tsaware:no /section:.text,ERP /section:.rdata,RP \
    /section:.data,RWP /section:.pdata,RP /section:INIT,ERD /timestamp:0 \
    /out:tegragpuprobe-unsigned.sys tegragpuprobe.obj kmdf_support.obj diagnostic_backend.obj \
    TegraGpuCore.lib $wdf/wdfdriverentry.lib $wdf/wdfldr.lib $km/ntoskrnl.lib $km/hal.lib \
    $km/ntstrsafe.lib $km/bufferoverflowfastfailk.lib
llvm-objdump-14 -h tegragpuprobe-unsigned.sys | grep -q "\.reloc" || { echo "ERROR: no .reloc section"; exit 1; }
osslsigncode sign -certs /cert/wifi-chain.crt -key /cert/wifi.key -h sha256 \
    -in tegragpuprobe-unsigned.sys -out /out/tegragpuprobe/tegragpuprobe.sys >/dev/null
for d in *.def; do llvm-dlltool-14 -m arm64 -d "$d" -l "${d%.def}.lib"; done
lld-link-14 /nologo /machine:arm64 /subsystem:windows,10.0 /entry:start /include:_load_config_used \
    /nodefaultlib /opt:ref /timestamp:0 /out:/out/performance-check/performance-check.exe \
    performance-check.obj msvcrt.lib kernel32.lib user32.lib gdi32.lib shell32.lib advapi32.lib \
    setupapi.lib cfgmgr32.lib
'
# DriverVer back-dated as for Wi-Fi: Inf2Cat on the console refuses a date in its future. The
# version is raised above the render driver's (both match SWOA0F01), so that installing the
# probe package selects it; deleting the probe package from the driver store goes back.
sed 's|^DriverVer=.*|DriverVer=05/02/2022,0.1.1.0|' "$R/windows/tegragpuprobe.inf" > "$PKG/tegragpuprobe.inf"
for f in NETB_img.bin fecs.bin gpccs.bin nv_acr_ucode_prod.bin pmu_bl.bin gpmu_ucode_image.bin \
        gpmu_ucode_desc.bin pmu_sig.bin fecs_sig.bin; do
    cp "$FW/$f" "$PKG/"
done
echo "Signed ARM64 KMDF probe package: $PKG; check tool: $TOOL/performance-check.exe"
