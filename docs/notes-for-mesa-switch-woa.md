# Switch OLED (Aula, HEG-001) results with tgd3d-vulkan

Field report from running this branch's WDDM display driver, tgd3d and NVK on a Mariko
**Switch OLED** (T210B01) under Windows 11 ARM64 23H2 (22631). Our loader chain differs:
Hekate → L4T bl31 → an EL2 shim → NintendoSwitchPkg UEFI. No winx, and we use the inbox SD stack.
Our project: https://github.com/DanilKhmyrov/windows-switch. Builds used: `35696545` (Nov 13), then
`a5d80906` (Nov 14) with a small local patch (StartDevice step statuses, see below).

## 1. The OLED panel works with the display build unchanged

Display A's boot mode on the OLED is identical to the Lite's. The registers read under Windows
before takeover match every value `tg_t214_dc_has_boot_mode` checks:

| register | value |
|---|---|
| COMMAND | `0x20` |
| OUTPUT_OPTIONS | `0x20000000` |
| SYNC / BACK / ACTIVE / FRONT | `0x00010048` / `0x00090048` / `0x050002D0` / `0x000A0088` |
| WIN_A OPTIONS / COLOR / SIZE / PRESCALED | `0x40000000` / `0xC` / `0x050002D0` / `0x05000B40` |
| WIN_A DDA / STRIDE / ADDR | `0x10001000` / `0x05A00B40` / `0xF5A00000` |

So the takeover works with the GPU0 `_CRS` from your winx patch (POST framebuffer, Display A,
GSI 105). The desktop came up in portrait, and Task Manager showed "Tegra X1 (GM20B)" with 3D load.

## 2. StartDevice can fail with STATUS_NO_MEMORY when started late

We added step statuses around `TgGpuDdiStartDevice`. A start about four minutes after boot failed
at step 2, `TgGpuCreateTableSegment`, with `0xC0000017`: the 16 MB contiguous table segment
(128 × 128 KB). Starting within about 1–2 minutes after logon always succeeded. This may matter
for logon-delayed activation on a busy or fragmented system.

## 3. Start-up hang: reproducible trigger and a workaround

These are hard hangs: no network, no dump, and no bugcheck even after five minutes with
`AutoReboot=0`. With the one-time permit on a running desktop, 3 of 5 switches hung within
**about 2.5 s** after StartDevice. The tgd3d ETW trace shows the same sequence each time:

1. DWM sets the mode;
2. DWM presents four rotated frames;
3. Explorer creates a second device;
4. both submit, then the trace stops.

There is no tgd3d error event. We decoded your kernel provider `{c27c1f9b-…}` raw (event 2,
152-byte payload). Up to the end of the hang traces it shows only successful `Preempt` records
(stages `GpuFence`, `Idle`, `Mappings`), with all cached FIFO/MMU/PBDMA/GR/FECS words zero. There
is no submit or worker failure, no recovery request and no reset. The traces were flushed every
1 s, so the final second is lost.

**Workaround, 5 of 5 starts OK:** suspend Explorer and the shell hosts during the switch
(NtSuspendProcess on explorer, StartMenuExperienceHost, SearchHost, TextInputHost and Widgets).
Let DWM run alone on the GPU for about 10 s, then resume them. Every run was still Code 0 30 s
after the resume. So the trigger is two processes' first GPU work at the same time, during start-up.

## 4. GPU-bridge tgd3d at `a5d80906`

It started fine with the workaround above. The present cost in the UMD was 0.3 ms median,
compared with 17 ms for the CPU-sync build. In CPU-sync mode we measured 12 presents/s on average
and up to 26 per 10 s window. With the bridge build: 14–19 presents/s under activity, and on-demand
presents when idle. That session hung after about 10 minutes with the browser and Explorer active,
again with no tgd3d or kernel error in the trace.

## 5. Not the cause: priv ring master timeouts

nvgpu's `gm20b_priv_set_timeout_settings` raises the master timeouts from `0x400` to `0x800` for
SYS station `0x15` (`0x122354`) and GPC station `0xa` (`0x128328`). Your frontend does not do
this. Adding it after the priv ring enable did not prevent the start-up hang: the second of two
starts without the workaround still hung.

Happy to run any diagnostic build on the OLED.
