// bl33 shim: our first code, started by Hekate after BL31.
//
// Hekate loads bl33.bin at 0xAA000000 and jumps here.
// It shows by colour that the code runs, sets up the UART and then
//   - in test mode (TEST_MODE=1) switches to 32-bit mode;
//   - in boot mode (TEST_MODE=0) copies UEFI to its address and starts it.
//
// The colours are chosen so that they do not depend on R/B byte order.

#define FB_BASE     0xF5A00000
#define FB_PIXELS   (720 * 1280)

#define GREEN       0xFF00FF00
#define MAGENTA     0xFFFF00FF
#define YELLOW_CYAN 0xFF00FFFF
#define BLACK       0xFF000000
#define TMR_US      0x60005010      // Tegra timer microsecond counter
#ifndef DELAY_MS
#define DELAY_MS    0
#endif

#define CAR_BASE    0x60006000
#define RST_DEV_L   0x04
#define CLK_ENB_L   0x10
#define UARTB_BIT   7

#define UART_BASE   0x70006040
#define UART_THR    0x00
#define UART_IER    0x04
#define UART_FCR    0x08
#define UART_LCR    0x0C
#define UART_MCR    0x10
#define UART_LSR    0x14
#define UART_SPR    0x1C
#define LSR_THRE    0x20
// 408 MHz / (16 * 115200), computed the same way as Hekate does.
#define UART_DIV    221

#define UEFI_BASE   0x80110000

// The EL2 vectors stay inside the shim; UEFI reserves this region from Windows.
#define TRAP_BASE   0xAA0FF000
#define TRAP_COUNT  (TRAP_BASE + 0xF00)
#define TRAP_STACK  (TRAP_BASE + 0xEF0)
#define TRAP_LIMIT  1000
#define TRAP_HOLD_TICKS (3 * 19200000)
#define TRAP_FIRST_ROW 40
#define TRAP_X      160
#define TRAP_WIDTH  400
#define FB_STRIDE   720
#define HCR_RW      (1 << 31)
#define HCR_AMO     (1 << 5)
#define HCR_FMO     (1 << 3)
#define HCR_TSC     (1 << 19)       // trap SMC from EL1
#define HCR_TACR    (1 << 21)       // trap ACTLR_EL1: signal from UEFI
#define SMP_TABLE   TRAP_BASE       // 16 bytes per core: entry point and context_id from Windows
#define PSCI_CPU_ON64 0xC4000003
#define PSCI_CPU_ON32 0x84000003
#define PSCI_SYSTEM_OFF 0x84000008
#define I2C5_BASE   0x7000D000      // PWR_I2C: MAX77620 PMIC at 0x3C
#define PMIC_ADDR   0x3C
#define PMIC_ONOFFCNFG1 0x41
#define PMIC_ONOFFCNFG2 0x42
#define UNEXPECTED_COLOR 0xFFFF0080
#define SHIM_MAGIC  0x5357534D      // reply to the UEFI signal: SMC trapping is on
#define SMC_TRACE   (TRAP_BASE + 0xF10)  // call counter for the on-screen trace
#define TRACE_Y     980
#define FIQ_COLOR   0xFF00FF00
#define SERROR_COLOR 0xFFFF00FF
#ifndef SHOW_TRACE
#define SHOW_TRACE  0               // on-screen squares tracing firmware calls
#endif
#define SMC_LOG     (TRAP_BASE + 0x500)  // 32 entries of 8 bytes: function ID and x1
#define MMIO_LOG    (TRAP_BASE + 0x100)  // 64 entries of 8 bytes: access descriptor and value
#define MMIO_SHOW   36
#define MMIO_COUNT  (TRAP_BASE + 0xF20)
#ifndef UHS_MODE
#define UHS_MODE    0               // experimental SD UHS-I (shim/build.py --uhs): 1 = DDR50,
                                    // 2 = SDR50 with the clock kept at 48 MHz,
                                    // 3 = SDR50 at 90.7 MHz with hardware tuning,
                                    // 4 = SDR104 at 204 MHz (and SDR50 as in 3)
#endif
#define UHS_STATE   (TRAP_BASE + 0xF30)  // flags, last host control 2, saved vendor clock control,
                                         // voltage switches; flags: 1 = 1.8 V, 2 = DDR50 clock,
                                         // 4 = autocal timed out, 8 = SDR50 run as SDR104
#define SD_BASE     0x700B0000
#define HANDOFF_PMIC (TRAP_BASE + 0xF40) // PMIC LDO6 and LDO2 config when UEFI hands over to
                                         // Windows, each 0x100 | value (0 = not read)
#define HCR_VM      (1 << 0)        // stage-2 translation for EL1
#define S2_L1       0xAA0FC000      // stage-2 tables (reserved memory)
#define S2_L2       0xAA0FD000      // 1..2 GB in 2 MB blocks
#define S2_L3       0xAA0FE000      // 0x70000000..0x701FFFFF in 4 KB pages
#define S2_BLOCK    0x7FD           // block: Normal WB (stage-1 attributes win), RW, AF
#define S2_PAGE     0x7FF
#define S2_TRAP_IDX 0xB0            // page 0x700B0000 (SDMMC1..4) is trapped
#define VTCR_VAL    0x8001305F      // T0SZ=31 (8 GB), start at L1, 4 KB, PS=36 bits, non-cacheable walks

.macro mov32 reg, value
    movz \reg, #((\value) & 0xFFFF)
    movk \reg, #(((\value) >> 16) & 0xFFFF), lsl #16
.endm

    .text
_start:
    b       start                   // +0x00
    .word   0                       // +0x04
    .ascii  "WPSHIM01"              // +0x08
    // +0x10: Hekate reads the DTB offset here. Zero points at the start of the file,
    // where there is no DTB, so the loader changes nothing.
    .word   0                       // +0x10
    .word   0                       // +0x14
payload_size:
    .quad   0                       // +0x18: filled in by build.py

start:
    msr     daifset, #0xF
    adr     x19, _start

#if CLEAN
    mov32   w0, BLACK               // Clean boot: just clear the Hekate screen.
#else
    mov32   w0, GREEN
#endif
    bl      fill_screen

#if DELAY_MS
    // Delay before UEFI: on Mariko the BPMP firmware is still training memory after Hekate,
    // and early UEFI used to hang after mark 6 at that time.
    mov32   x1, TMR_US
    ldr     w2, [x1]
    mov32   w3, (DELAY_MS * 1000)
1:  ldr     w4, [x1]
    sub     w4, w4, w2
    cmp     w4, w3
    b.lo    1b
#endif
    bl      uart_setup              // x20 = 1 if the UART is available
    adr     x0, msg_hello
    bl      puts
    mrs     x21, CurrentEL
    ubfx    x21, x21, #2, #2
    adr     x0, msg_el
    bl      puts
    add     w0, w21, #'0'
    bl      putc
    adr     x0, msg_nl
    bl      puts

    cmp     x21, #2
    b.eq    el_ok
    mov32   w0, MAGENTA             // Not EL2: cannot go on.
    bl      fill_screen
    b       halt

el_ok:
#if TEST_MODE
    adr     x1, a32_code
    mov     x0, x20                 // Goes to r0: whether the UART is available.
    b       enter_aarch32
#else
    ldr     x2, payload_size
    cbz     x2, no_payload
    adr     x0, payload
    mov32   x1, UEFI_BASE
1:  ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    x2, x2, #1
    b.ne    1b

    adr     x0, msg_jump
    bl      puts
#if !CLEAN
    mov32   w0, YELLOW_CYAN
    bl      fill_screen
#endif

    dsb     sy
    ic      iallu
    dsb     sy
    isb
#if CHAIN_A32
    mov     x0, xzr
    mov32   x1, UEFI_BASE
    b       enter_aarch32
#else
    mov32   x1, UEFI_BASE
    bl      build_s2
    b       enter_aarch64_el1
#endif

no_payload:
    mov32   w0, MAGENTA
    bl      fill_screen
#endif

halt:
    wfe
    b       halt

// Stage-2 tables: everything is identity-mapped except page 0x700B0000.
// Clobbers x9-x14.
build_s2:
    mov32   x9, S2_L1
    mov     x12, #S2_BLOCK
    str     x12, [x9]               // 0..1 GB
    mov32   x10, (S2_L2 | 3)
    str     x10, [x9, #8]           // 1..2 GB -> L2
    mov     x11, #2
1:  lsl     x10, x11, #30
    orr     x10, x10, x12
    str     x10, [x9, x11, lsl #3]
    add     x11, x11, #1
    cmp     x11, #8
    b.lo    1b
    mov32   x9, S2_L2
    mov     x11, #0
2:  lsl     x10, x11, #21
    orr     x10, x10, #0x40000000
    orr     x10, x10, x12
    cmp     x11, #384               // 0x70000000 -> L3
    b.ne    3f
    mov32   x10, (S2_L3 | 3)
3:  str     x10, [x9, x11, lsl #3]
    add     x11, x11, #1
    cmp     x11, #512
    b.lo    2b
    mov32   x9, S2_L3
    mov     x13, #S2_PAGE
    mov     x11, #0
4:  lsl     x10, x11, #12
    orr     x10, x10, #0x70000000
    orr     x10, x10, x13
    cmp     x11, #S2_TRAP_IDX
    b.ne    5f
    mov     x10, xzr
5:  str     x10, [x9, x11, lsl #3]
    add     x11, x11, #1
    cmp     x11, #512
    b.lo    4b
    dsb     sy
    ret

#if !TEST_MODE && !CHAIN_A32
// Switch to 64-bit EL1: Windows expects to run at EL1, not EL2.
// x1 = UEFI address.
enter_aarch64_el1:
    mrs     x2, midr_el1
    msr     vpidr_el2, x2
    mrs     x2, mpidr_el1
    msr     vmpidr_el2, x2
    mov32   x3, TRAP_COUNT
    str     wzr, [x3]
    mov32   x3, MMIO_COUNT
    str     wzr, [x3]
#if UHS_MODE
    bl      uhs_boot_init           // same size as the dsb it replaces (it does the dsb)
#else
    dsb     sy
#endif
    adr     x3, trap_start
    msr     vbar_el2, x3
    // The handler stack is SP_EL2: the CPU uses it on exception entry. Without SPSel=1
    // "mov sp" could set SP_EL0, and the very first trap looped forever.
    msr     spsel, #1
    mov32   x3, TRAP_STACK
    mov     sp, x3
    mov32   x3, SMC_TRACE
    str     wzr, [x3]
    // SMC is not trapped yet. UEFI signals the hand-off to the OS by reading
    // ACTLR_EL1 (TACR trap). HVC does not work: ATF may disable it (SCR_EL3.HCE).
    mov32   x2, (HCR_RW | HCR_AMO | HCR_FMO | HCR_TACR)
    msr     hcr_el2, x2
    mov32   x2, 0x33FF              // Do not trap FP and SIMD.
    msr     cptr_el2, x2
    msr     hstr_el2, xzr
    // MDCR_EL2: do not trap debug and performance counters; all counters belong to EL1.
    mrs     x2, pmcr_el0
    ubfx    x2, x2, #11, #5
    msr     mdcr_el2, x2
    mov     x2, #3                  // EL1 access to the counter and timer.
    msr     cnthctl_el2, x2
    msr     cntvoff_el2, xzr
    mov32   x2, 0x30C50838          // SCTLR reset value: MMU and caches off.
    msr     sctlr_el1, x2
    mov     x2, #0x3C5              // EL1h, interrupts masked.
    msr     spsr_el2, x2
    msr     elr_el2, x1
    mov     x0, xzr
    mov     x1, xzr
    mov     x2, xzr
    mov     x3, xzr
    dsb     sy
    isb
    eret
#endif

#if !TEST_MODE && !CHAIN_A32
    .balign 2048
trap_start:
    .skip   0x400                   // up to the vectors for EL1 (AArch64)
    b       el1_pre                 // +0x400: synchronous exception from EL1 (SMC, HVC)
    .balign 128
    b       .                       // +0x480: IRQ from EL1 (never routed here)
    .balign 128
    stp     x0, x1, [sp, #-16]!     // +0x500: FIQ from EL1
    mov32   w0, FIQ_COLOR
    b       trap_paint
    .balign 128
    b       serror_note             // +0x580: SError from EL1
    .balign 128
// w0 = colour. Every event draws a new bar; after the limit the trap is disabled.
trap_paint:
    stp     x2, x3, [sp, #-16]!
    mov32   x1, TRAP_COUNT
    ldr     w2, [x1]
    add     w3, w2, #1
    str     w3, [x1]
    cbnz    w2, 3f
    // First event: fill the whole screen and hold the colour so it can be seen.
    mov32   x1, FB_BASE
    mov32   w3, FB_PIXELS
2:  str     w0, [x1], #4
    subs    w3, w3, #1
    b.ne    2b
    dsb     sy
    mrs     x1, cntpct_el0
    mov32   x3, TRAP_HOLD_TICKS
    add     x1, x1, x3
4:  mrs     x3, cntpct_el0
    cmp     x3, x1
    b.lo    4b
3:  cmp     w2, #TRAP_LIMIT
    b.hs    trap_off
    add     w2, w2, #TRAP_FIRST_ROW
    mov     w3, #FB_STRIDE
    mul     x2, x2, x3
    add     x2, x2, #TRAP_X
    mov32   x1, FB_BASE
    add     x1, x1, x2, lsl #2
    mov     w3, #TRAP_WIDTH
1:  str     w0, [x1], #4
    subs    w3, w3, #1
    b.ne    1b
    dsb     sy
    b       trap_ret
trap_off:
    mrs     x2, hcr_el2
    mov     x3, #(HCR_AMO | HCR_FMO)
    bic     x2, x2, x3
    msr     hcr_el2, x2
    isb
trap_ret:
    ldp     x2, x3, [sp], #16
    ldp     x0, x1, [sp], #16
    eret

// SMC (trapped via HCR_EL2.TSC) or HVC from EL1. The call goes to ATF unchanged,
// except PSCI CPU_ON: ATF starts new cores at EL2, so the entry point is replaced
// with secondary_entry, which drops the core to EL1 and jumps to the Windows entry point.
el1_sync:
    stp     x4, x5, [sp, #-16]!
    mrs     x4, esr_el2
    lsr     x4, x4, #26
    cmp     x4, #0x17               // SMC from AArch64
    b.eq    1f
    cmp     x4, #0x16               // HVC from AArch64
    b.eq    1f
    cmp     x4, #0x18               // MRS/MSR: ACTLR_EL1 read, the signal from UEFI
    b.eq    12f
    cmp     x4, #0x24               // EL1 access to the trapped page (stage 2)
    b.eq    mmio_trap
    mov32   w0, UNEXPECTED_COLOR
    bl      fill_screen
    mrs     x4, esr_el2
    bl      show_bits               // 32 bits of ESR_EL2: white = 1, black = 0
    b       .
1:  stp     x6, x30, [sp, #-16]!    // x30 is a Windows register, bl clobbers it
    bl      trace_mark              // red: the call went to ATF
    // log: function ID and x1 into a 32-entry ring buffer
    mov32   x4, SMC_TRACE
    ldr     w5, [x4]
    sub     w5, w5, #1
    and     w5, w5, #31
    mov32   x4, SMC_LOG
    add     x4, x4, x5, lsl #3
    stp     w0, w1, [x4]
    dsb     sy
    ldp     x6, x30, [sp], #16
    b       11f
12: mov32   x5, S2_L1               // UEFI: Windows is starting. Stage 2 on,
    msr     vttbr_el2, x5           // SMC trapping on, ACTLR trapping off.
    mov32   x5, VTCR_VAL
    msr     vtcr_el2, x5
    isb
    mrs     x5, hcr_el2
    orr     x5, x5, #HCR_TSC
    orr     x5, x5, #HCR_VM
    bic     x5, x5, #HCR_TACR
    msr     hcr_el2, x5
    isb
    tlbi    vmalls12e1
    dsb     sy
    isb
#if SHOW_TRACE
    // Blue 24x24 square left of the trace row: the signal was received.
    stp     x6, x7, [sp, #-16]!
    mov32   x6, (FB_BASE + (TRACE_Y * FB_STRIDE + 8) * 4)
    mov32   w7, 0xFF2060FF
    mov     x5, #24
9:  mov     x4, #24
10: str     w7, [x6], #4
    subs    x4, x4, #1
    b.ne    10b
    add     x6, x6, #((FB_STRIDE - 24) * 4)
    subs    x5, x5, #1
    b.ne    9b
    dsb     sy
    ldp     x6, x7, [sp], #16
#endif
#if UHS_MODE
    b       handoff_probe           // same size as the movz it replaces (it does the movz)
.Lsig_back:
    movk    x0, #((SHIM_MAGIC >> 16) & 0xFFFF), lsl #16
#else
    mov32   x0, SHIM_MAGIC          // UEFI reads ACTLR_EL1 into x0
#endif
    mrs     x5, elr_el2
    add     x5, x5, #4
    msr     elr_el2, x5
    ldp     x4, x5, [sp], #16
    eret
11: mov32   x5, PSCI_CPU_ON64
    cmp     x0, x5
    b.eq    2f
    mov32   x5, PSCI_CPU_ON32
    cmp     x0, x5
    b.ne    3f
2:  and     x5, x1, #0xFF           // core number (Aff0)
    cmp     x5, #4
    b.hs    3f
    mov32   x4, SMP_TABLE
    add     x4, x4, x5, lsl #4
    stp     x2, x3, [x4]            // entry point and context_id from Windows
    dsb     sy
    adr     x2, secondary_entry
    mov     x3, x5                  // context for secondary_entry: core number
3:  smc     #0
    stp     x6, x30, [sp, #-16]!
    bl      trace_mark_done         // green: ATF returned
    ldp     x6, x30, [sp], #16
    mrs     x5, esr_el2
    lsr     x5, x5, #26
    cmp     x5, #0x17               // after an SMC, return past the instruction
    b.ne    4f
    mrs     x5, elr_el2
    add     x5, x5, #4
    msr     elr_el2, x5
4:  ldp     x4, x5, [sp], #16
    eret

// A 12x12 square in the trace row. trace_mark takes the next number and paints it red,
// trace_mark_done repaints the current one green. Clobbers x6 (and x30 via bl), saved by
// the caller; x7-x9 are saved here.
trace_mark:
    stp     x7, x8, [sp, #-16]!
    mov32   x7, SMC_TRACE
    ldr     w6, [x7]
    add     w6, w6, #1
    str     w6, [x7]
    ldp     x7, x8, [sp], #16
    mov32   w6, 0xFFFF2020
    b       6f
trace_mark_done:
    mov32   w6, 0xFF20FF20
6:
#if !SHOW_TRACE
    ret
#endif
    stp     x7, x10, [sp, #-16]!
    stp     x8, x9, [sp, #-16]!
    mov32   x7, SMC_TRACE
    ldr     w8, [x7]
    sub     w8, w8, #1
    and     w9, w8, #31             // 32 squares per row
    lsr     w8, w8, #5
    and     w8, w8, #7              // up to 8 rows
    mov     w7, #16
    mul     w9, w9, w7
    add     w9, w9, #40             // x (the blue "signal received" square is to the left)
    mul     w8, w8, w7
    add     w8, w8, #TRACE_Y        // y
    mov     w7, #FB_STRIDE
    madd    w8, w8, w7, w9
    mov32   x7, FB_BASE
    add     x7, x7, x8, lsl #2
    mov     w9, #12
7:  mov     w8, #12
8:  str     w6, [x7], #4
    subs    w8, w8, #1
    b.ne    8b
    add     x7, x7, #((FB_STRIDE - 12) * 4)
    subs    w9, w9, #1
    b.ne    7b
    dsb     sy
    ldp     x8, x9, [sp], #16
    ldp     x7, x10, [sp], #16
    ret

// SError from EL1: the screen is not cleared. The top row (y = 8) shows the 32 bits of ESR_EL2
// of the latest error as 12x12 squares (white = 1, grey = 0); below it, a bar counts errors.
// The error is skipped and Windows keeps running.
// Windows access to page 0x700B0000: perform it ourselves with the same width and log it.
mmio_trap:
    ldp     x4, x5, [sp], #16
    sub     sp, sp, #256
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    str     x30, [sp, #240]
    mrs     x0, esr_el2
    tbz     x0, #24, mmio_bad       // no instruction syndrome (ISV=0)
    mrs     x1, hpfar_el2
    lsr     x1, x1, #4
    lsl     x1, x1, #12
    mrs     x2, far_el2
    and     x2, x2, #0xFFF
    orr     x1, x1, x2              // physical address
    ubfx    x3, x0, #16, #5         // register number
    ubfx    x4, x0, #22, #2         // width: 0=1, 1=2, 2=4, 3=8 bytes
    mov     x5, xzr
    cmp     x3, #31
    b.eq    1f
    ldr     x5, [sp, x3, lsl #3]
#if UHS_MODE
1:  b       uhs_pre                 // same size: the handler keeps its addresses (see uhs_pre)
#else
1:  tbz     x0, #6, 5f
#endif
.Lmmio_write:
    cmp     x4, #0                  // write
    b.ne    2f
    strb    w5, [x1]
    b       20f
2:  cmp     x4, #1
    b.ne    3f
    strh    w5, [x1]
    b       20f
3:  cmp     x4, #2
    b.ne    4f
    str     w5, [x1]
    b       20f
4:  str     x5, [x1]
    b       20f
.Lmmio_read:
5:  cmp     x4, #0                  // read
    b.ne    6f
    ldrb    w5, [x1]
    tbz     x0, #21, 9f
    sxtb    x5, w5
    b       9f
6:  cmp     x4, #1
    b.ne    7f
    ldrh    w5, [x1]
    tbz     x0, #21, 9f
    sxth    x5, w5
    b       9f
7:  cmp     x4, #2
    b.ne    8f
    ldr     w5, [x1]
    tbz     x0, #21, 9f
    sxtw    x5, w5
    b       9f
8:  ldr     x5, [x1]
9:  // SDMMC1 capabilities (0x40): clear bit 28 "64-bit system bus". Then sdbus uses 32-bit
    // DMA and buffers below 4 GB, like ARM32. With addresses above 4 GB the controller DMA hung the bus.
    mov32   x6, 0x700B0040
    cmp     x1, x6
#if UHS_MODE
    b.ne    uhs_read
#else
    b.ne    13f
#endif
    and     x5, x5, #0xffffffffefffffff
    // Base clock (bits 15:8): the register says 208 MHz, but UEFI clocks SDMMC1 at 48 MHz
    // (PLLP / 8.5). sdbus divided the 208 by 6 for 50 MHz and the card ran at 8 MHz (3 MB/s).
    // With the real 48 MHz it uses no divider: SD high speed at 48 MHz.
    and     x5, x5, #0xffffffffffff00ff
    orr     x5, x5, #0x3000
.Lmmio_read_done:
13: tbnz    x0, #15, 10f            // SF: 64-bit register
    mov     w5, w5
10: cmp     x3, #31
    b.eq    20f
    str     x5, [sp, x3, lsl #3]
20: dsb     sy
    // log: (address & 0xFFFF) | width << 16 | write << 18, then the value
    mov32   x6, MMIO_COUNT
    ldr     w7, [x6]
    and     w8, w7, #63
    add     w7, w7, #1
    str     w7, [x6]
    mov32   x6, MMIO_LOG
    add     x6, x6, x8, lsl #3
    and     w9, w1, #0xFFFF
    orr     w9, w9, w4, lsl #16
    ubfx    x10, x0, #6, #1
    orr     w9, w9, w10, lsl #18
    stp     w9, w5, [x6]
    mrs     x6, elr_el2
    add     x6, x6, #4
    msr     elr_el2, x6
    ldp     x0, x1, [sp, #0]
    ldp     x2, x3, [sp, #16]
    ldp     x4, x5, [sp, #32]
    ldp     x6, x7, [sp, #48]
    ldp     x8, x9, [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldr     x30, [sp, #240]
    add     sp, sp, #256
    eret
mmio_bad:
    mov32   w0, UNEXPECTED_COLOR
    bl      fill_screen
    mrs     x4, esr_el2
    bl      show_bits
    b       .

serror_note:
    stp     x0, x1, [sp, #-16]!
    stp     x2, x3, [sp, #-16]!
    stp     x4, x5, [sp, #-16]!
    stp     x6, x7, [sp, #-16]!
    stp     x8, x9, [sp, #-16]!
    stp     x10, x11, [sp, #-16]!
    stp     x12, x13, [sp, #-16]!
    stp     x29, x30, [sp, #-16]!
    mov32   x0, TRAP_COUNT
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]
    mov     w13, w1
    mrs     x4, esr_el2
    mov     x9, #8
    bl      row32
    // first error only: ELR_EL2 and ELR_EL1 (low 32 bits) and the SD access log
    cmp     w13, #1
    b.ne    6f
    mrs     x4, elr_el2
    mov     x9, #40
    bl      row32
    mrs     x4, elr_el1
    mov     x9, #56
    bl      row32
    // SD page access log: total count, then the latest entries (descriptor, value)
    mov32   x11, MMIO_COUNT
    ldr     w4, [x11]
    mov     w12, w4
    mov     x9, #80
    bl      row32
    mov     x10, #0
7:  add     w1, w12, w10
    sub     w1, w1, #MMIO_SHOW
    and     w1, w1, #63
    mov32   x11, MMIO_LOG
    add     x11, x11, x1, lsl #3
    ldr     w4, [x11]
    lsl     x9, x10, #5
    add     x9, x9, #96
    bl      row32
    ldr     w4, [x11, #4]
    lsl     x9, x10, #5
    add     x9, x9, #112
    bl      row32
    add     x10, x10, #1
    cmp     x10, #MMIO_SHOW
    b.lo    7b
6:  // counter: a bar min(n, 500) pixels long at y = 24
    mov     w1, w13
    cmp     w1, #500
    mov     w2, #500
    csel    w1, w1, w2, lo
    mov32   x3, (FB_BASE + (24 * FB_STRIDE + 8) * 4)
    mov32   w7, SERROR_COLOR
5:  str     w7, [x3], #4
    subs    w1, w1, #1
    b.ne    5b
    dsb     sy
    ldp     x29, x30, [sp], #16
    ldp     x12, x13, [sp], #16
    ldp     x10, x11, [sp], #16
    ldp     x8, x9, [sp], #16
    ldp     x6, x7, [sp], #16
    ldp     x4, x5, [sp], #16
    ldp     x2, x3, [sp], #16
    ldp     x0, x1, [sp], #16
    eret

// Draws the 32 bits of w4 (MSB first) as 12x12 squares on row y = x9, in groups of 4 bits.
// White = 1, grey = 0. Clobbers x0, x2, x3, x5, x6, x7.
row32:
    mov     x5, #31
1:  lsr     x6, x4, x5
    and     x6, x6, #1
    mov32   w7, 0xFF404040
    cbz     x6, 2f
    mov32   w7, 0xFFFFFFFF
2:  mov     x2, #31
    sub     x2, x2, x5              // square number 0..31
    lsr     x3, x2, #2              // group number
    mov     x0, #6
    mul     x3, x3, x0
    lsl     x2, x2, #4
    add     x2, x2, x3
    add     x2, x2, #8              // x
    mov     x3, #FB_STRIDE
    madd    x2, x9, x3, x2
    mov32   x3, FB_BASE
    add     x3, x3, x2, lsl #2
    mov     x2, #12
3:  mov     x0, #12
4:  str     w7, [x3], #4
    subs    x0, x0, #1
    b.ne    4b
    add     x3, x3, #((FB_STRIDE - 12) * 4)
    subs    x2, x2, #1
    b.ne    3b
    subs    x5, x5, #1
    b.pl    1b
    ret


// Draws the 32 bits of x4 (MSB first) as 36x36 squares in two rows of 16, starting at y = 560.
show_bits:
    mov     x5, #31
1:  lsr     x6, x4, x5
    and     x6, x6, #1
    mov32   w7, 0xFF000000
    cbz     x6, 2f
    mov32   w7, 0xFFFFFFFF
2:  mov     x8, #31
    sub     x8, x8, x5              // square number 0..31
    and     x9, x8, #15
    lsr     x8, x8, #4
    mov     x10, #44
    mul     x9, x9, x10
    add     x9, x9, #8              // x
    mul     x8, x8, x10
    add     x8, x8, #560            // y
    mov     x10, #FB_STRIDE
    madd    x8, x8, x10, x9
    mov32   x10, FB_BASE
    add     x10, x10, x8, lsl #2
    mov     x11, #36
3:  mov     x12, #36
4:  str     w7, [x10], #4
    subs    x12, x12, #1
    b.ne    4b
    add     x10, x10, #((FB_STRIDE - 36) * 4)
    subs    x11, x11, #1
    b.ne    3b
    subs    x5, x5, #1
    b.pl    1b
    dsb     sy
    ret

// ATF starts a new core here (EL2, AArch64, MMU off), x0 = core number.
secondary_entry:
    msr     daifset, #0xF
    mov     x9, x0
    msr     spsel, #1
    mov32   x1, TRAP_STACK
    sub     x1, x1, x9, lsl #9
    mov     sp, x1
    adr     x1, trap_start
    msr     vbar_el2, x1
    mrs     x1, midr_el1
    msr     vpidr_el2, x1
    mrs     x1, mpidr_el1
    msr     vmpidr_el2, x1
    // stage 2 as on the first core: accesses to the SD page are trapped
    mov32   x1, S2_L1
    msr     vttbr_el2, x1
    mov32   x1, VTCR_VAL
    msr     vtcr_el2, x1
    isb
    mov32   x1, (HCR_RW | HCR_AMO | HCR_FMO | HCR_TSC | HCR_VM)
    msr     hcr_el2, x1
    isb
    tlbi    vmalls12e1
    dsb     sy
    mov32   x1, 0x33FF
    msr     cptr_el2, x1
    msr     hstr_el2, xzr
    mrs     x1, pmcr_el0
    ubfx    x1, x1, #11, #5
    msr     mdcr_el2, x1
    mov     x1, #3
    msr     cnthctl_el2, x1
    msr     cntvoff_el2, xzr
    mov32   x1, 0x30C50838
    msr     sctlr_el1, x1
    mov32   x1, SMP_TABLE
    add     x1, x1, x9, lsl #4
    ldp     x2, x0, [x1]            // x2 = Windows entry point, x0 = its context_id
    msr     elr_el2, x2
    mov     x1, #0x3C5              // EL1h, interrupts masked
    msr     spsr_el2, x1
    mov     x1, xzr
    mov     x2, xzr
    mov     x3, xzr
    dsb     sy
    isb
    eret

// Added code goes here, at the end of the resident part, so that everything before keeps
// its offsets: a 16-byte shift of el1_sync made early UEFI hang after mark 6 (the trap
// handler also runs before Windows, for ACTLR and the A57 auxiliary registers), while the
// same amount of padding after it did not.
// First look at a synchronous exception: SMC/HVC PSCI SYSTEM_OFF powers the console off,
// anything else goes to el1_sync unchanged.
el1_pre:
    stp     x4, x5, [sp, #-16]!
    mrs     x4, esr_el2
    lsr     x4, x4, #26
    cmp     x4, #0x17               // SMC from AArch64
    b.eq    .Lpre_call
    cmp     x4, #0x16               // HVC from AArch64
    b.ne    .Lpre_out
.Lpre_call:
    mov32   x5, PSCI_SYSTEM_OFF
    cmp     x0, x5
    b.eq    pmic_off
.Lpre_out:
    ldp     x4, x5, [sp], #16
    b       el1_sync

// PSCI SYSTEM_OFF (Windows "Shut down"): ATF does not remove power on the Switch (Linux does
// it in its PMIC driver), so the console stayed on until the 12 s button press. Do what hekate's
// POWER_OFF_RESET does: ONOFFCNFG2 without the soft-reset, ALARM1 and ALARM2 wake-ups, then
// ONOFFCNFG1 = SFT_RST (power down, regulators reset). Windows has stopped everything else by
// now; this never returns.
pmic_off:
    mov32   x7, I2C5_BASE
    mov     w6, #PMIC_ONOFFCNFG2
    mov     w9, #0                  // write the register address
    bl      i2c5_xfer
    mov     w9, #1                  // read one byte
    bl      i2c5_xfer
    ldr     w6, [x7, #0x0C]
    and     w6, w6, #0xFF
    mov     w10, #0x86              // SFT_RST_WK | WK_ALARM1 | WK_ALARM2
    bic     w6, w6, w10
    lsl     w6, w6, #8
    add     w6, w6, #PMIC_ONOFFCNFG2  // the low byte is 0 after the shift
    mov     w9, #2                  // write register + value
    bl      i2c5_xfer
    mov     w6, #((0x80 << 8) | PMIC_ONOFFCNFG1)
    mov     w9, #2
    bl      i2c5_xfer
.Lpo1:  wfi
    b       .Lpo1

// One Tegra I2C transfer to the PMIC on I2C5 (x7 = controller, w6 = data, w9: 0 = write
// 1 byte, 1 = read 1 byte, 2 = write 2 bytes). Same sequence as the UEFI CpuI2c. Clobbers w8, w10.
i2c5_xfer:
    mov     w8, #(PMIC_ADDR << 1)
    cmp     w9, #1
    cinc    w8, w8, eq              // read: address | 1
    str     w8, [x7, #0x04]         // CMD_ADDR0
    str     w6, [x7, #0x0C]         // CMD_DATA1
    mov     w8, #0x2800             // NEW_MASTER_FSM, debounce
    cmp     w9, #1
    b.ne    .Lpo2
    orr     w8, w8, #(1 << 6)       // read
.Lpo2:  cmp     w9, #2
    b.ne    .Lpo3
    orr     w8, w8, #(1 << 1)       // 2 bytes
.Lpo3:  str     w8, [x7, #0x00]         // CNFG
    mov     w8, #0x25
    str     w8, [x7, #0x8C]         // CONFIG_LOAD
    mov     w10, #20000
.Lpo4:  ldr     w8, [x7, #0x8C]
    tbz     w8, #0, .Lpo5
    subs    w10, w10, #1
    b.ne    .Lpo4
.Lpo5:  ldr     w8, [x7, #0x00]
    orr     w8, w8, #(1 << 9)       // GO
    str     w8, [x7, #0x00]
    mov32   w10, 0x100000
.Lpo6:  ldr     w8, [x7, #0x1C]         // STATUS: busy
    tbz     w8, #8, .Lpo7
    subs    w10, w10, #1
    b.ne    .Lpo6
.Lpo7:  ret

    .balign 8
trap_end:
#endif

#if TEST_MODE || CHAIN_A32
// Switch to AArch32: the lower level (EL1) will be 32-bit.
// x0 goes to r0, x1 = address of the 32-bit code. This path was checked with the white screen.
enter_aarch32:
    msr     hcr_el2, xzr
    msr     cptr_el2, xzr
    msr     hstr_el2, xzr
    // UEFI runs at EL1, so give it access to the timer.
    mov     x2, #3
    msr     cnthctl_el2, x2
    msr     cntvoff_el2, xzr
    mov32   x2, 0x00C50838          // SCTLR reset value: MMU and caches off.
    msr     sctlr_el1, x2
    mov     x2, #0x1D3              // SVC mode, interrupts masked.
    msr     spsr_el2, x2
    msr     elr_el2, x1
    dsb     sy
    isb
    eret
#endif

// w0 = colour. Clobbers x1, x2.
fill_screen:
    mov32   x1, FB_BASE
    mov32   x2, FB_PIXELS
1:  str     w0, [x1], #4
    subs    x2, x2, #1
    b.ne    1b
    dsb     sy
    ret

// Accessing the UART with its clock off can hang the bus,
// so ask the clock controller first.
uart_setup:
    mov     x20, #0
    mov32   x1, CAR_BASE
    ldr     w2, [x1, #CLK_ENB_L]
    tbz     w2, #UARTB_BIT, 9f
    ldr     w2, [x1, #RST_DEV_L]
    tbnz    w2, #UARTB_BIT, 9f

    mov32   x1, UART_BASE
    str     wzr, [x1, #UART_IER]
    mov     w2, #0x83               // DLAB + 8 bits
    str     w2, [x1, #UART_LCR]
    mov     w2, #UART_DIV
    str     w2, [x1, #UART_THR]
    str     wzr, [x1, #UART_IER]
    mov     w2, #0x03               // 8n1
    str     w2, [x1, #UART_LCR]
    ldr     w2, [x1, #UART_SPR]
    mov     w2, #0x01
    str     w2, [x1, #UART_FCR]
    ldr     w2, [x1, #UART_SPR]
    str     wzr, [x1, #UART_MCR]
    mov     w2, #0x07               // Clear the FIFOs
    str     w2, [x1, #UART_FCR]
    mov     x20, #1
9:  ret

// w0 = character. Clobbers x1, x2, x3.
putc:
    cbz     x20, 3f
    mov32   x1, UART_BASE
    mov32   w3, 0x100000            // Wait limit: never hang on the UART.
1:  ldr     w2, [x1, #UART_LSR]
    tbnz    w2, #5, 2f
    subs    w3, w3, #1
    b.ne    1b
    ret
2:  str     w0, [x1, #UART_THR]
3:  ret

// x0 = string. Clobbers x0-x4, keeps the return address in x5.
puts:
    mov     x5, x30
    mov     x4, x0
1:  ldrb    w0, [x4], #1
    cbz     w0, 2f
    bl      putc
    b       1b
2:  ret     x5

msg_hello:  .asciz "\r\n[wp-shim] started\r\n"
msg_el:     .asciz "[wp-shim] CurrentEL="
msg_nl:     .asciz "\r\n"
msg_jump:   .asciz "[wp-shim] jumping to UEFI\r\n"
    .balign 4

#if TEST_MODE
a32_code:
    .incbin A32_BIN
#endif

#if UHS_MODE && !TEST_MODE && !CHAIN_A32
// UHS state reset at boot (DRAM keeps it over a reboot).
uhs_boot_init:
    mov32   x3, UHS_STATE
    stp     xzr, xzr, [x3]
    stp     xzr, xzr, [x3, #16]     // and HANDOFF_PMIC
    dsb     sy
    ret

// At the UEFI hand-off (ACTLR_EL1 signal): read the MAX77620 LDO6 (touch panel, 0x2F) and LDO2
// (SD I/O, 0x27) configs for swbatt's log (values before any change), and put LDO6 at 2.9 V. Windows drivers have not started, I2C5 is free.
// Keeps every register except x0 (set by the caller right after), x4 and x5 (saved by it).
handoff_probe:
    stp     x6, x7, [sp, #-48]!
    stp     x8, x9, [sp, #16]
    stp     x10, x30, [sp, #32]
    mov32   x7, I2C5_BASE
    mov32   x4, HANDOFF_PMIC
    mov     w6, #0x2F
    bl      1f
    str     w6, [x4]
    // The touch panel rail must be 2.9 V (Switchroot "vdd-tp-2v9", hekate touch_power_on). After a
    // cold start UEFI leaves it at 1.0 V (0xC4), after a reboot at 2.8 V. If LDO6 is on (power
    // mode bits 7:6 = 3) at another voltage, set 2.9 V and keep the mode; swhid checks it again.
    and     w8, w6, #0xC0
    cmp     w8, #0xC0
    b.ne    2f
    and     w8, w6, #0x3F
    cmp     w8, #0x2A
    b.eq    2f
    mov     w6, #((0xC0 | 0x2A) << 8)
    add     w6, w6, #0x2F
    mov     w9, #2
    bl      i2c5_xfer
2:
    mov     w6, #0x27
    bl      1f
    str     w6, [x4, #4]
    dsb     sy
    ldp     x10, x30, [sp, #32]
    ldp     x8, x9, [sp, #16]
    ldp     x6, x7, [sp], #48
    movz    x0, #(SHIM_MAGIC & 0xFFFF)
    b       .Lsig_back
1:  mov     x5, x30                 // w6 = register -> w6 = 0x100 | value
    mov     w9, #0
    bl      i2c5_xfer
    mov     w9, #1
    bl      i2c5_xfer
    ldr     w6, [x7, #0x0C]
    and     w6, w6, #0xFF
    orr     w6, w6, #0x100
    ret     x5

// SD UHS-I DDR50 under Windows. sdbus does the SD side (CMD11, CMD6) and the standard SDHCI
// registers; the Tegra side is done here, when sdbus writes the register that needs it, with
// the steps of hekate's sdmmc_enable_low_voltage and sdmmc_setup_clock (T210B01 values):
// - host control 2 gets VDD_180: I/O rail LDO2 to 1.8 V, PMC pads to 1.8 V, Schmitt triggers,
//   pad autocalibration, power control 1.8 V; cleared again: back to 3.3 V.
// - host control 2 selects DDR50: SDMMC1 clock 81.6 MHz from PLLP, tap 11, and the SDHCI
//   divider at least 2 (40.8 MHz on the card; sdbus thinks the base clock is 48 MHz).
// - reset all while DDR50 is on: clock back to 48 MHz for the new identification.
// In: x1 = address, x4 = width (1 = 16 bit, 2 = 32 bit), x5 = value. Keeps x0-x4, may change
// x5. Clobbers x6-x17. Runs with interrupts masked, at most ~15 ms.
// Entry points from mmio_trap. The early UEFI hangs (squares 2 and 6) when code inside the trap
// handler moves, so the handler only has two branch instructions changed and everything new
// is here, after it.
uhs_pre:
    tbz     x0, #6, .Lmmio_read
    bl      uhs_write_hook          // may change x5 (the value); keeps x0-x4
    b       .Lmmio_write

// Read of any SD page register except capabilities 0; x1 = address, x4 = width, x5 = value.
uhs_read:
    mov32   x6, 0x700B0044          // capabilities 1: add one UHS mode (UEFI hides SDR50/SDR104)
    cmp     x1, x6
    b.ne    1f
#if UHS_MODE == 1
    orr     x5, x5, #4              // DDR50
#elif UHS_MODE == 2
    orr     x5, x5, #1              // SDR50
    bic     x5, x5, #(1 << 13)      // without tuning (fixed tap at 48 MHz)
#elif UHS_MODE == 3
    orr     x5, x5, #1              // SDR50, with tuning (bit 13 stays)
#else
    orr     x5, x5, #3              // SDR50 and SDR104, with tuning
#endif
    b       .Lmmio_read_done
1:
#if UHS_MODE >= 2
    // host control 2 while SDR50 runs as SDR104 (T210 errata): show sdbus its own mode 2
    mov32   x6, UHS_STATE
    ldr     w7, [x6]
    tbz     w7, #3, .Lmmio_read_done
    mov32   x6, 0x700B003E
    cmp     x1, x6
    b.ne    2f
    cmp     x4, #1
    b.ne    .Lmmio_read_done
    bic     x5, x5, #1
    b       .Lmmio_read_done
2:  mov32   x6, 0x700B003C
    cmp     x1, x6
    b.ne    .Lmmio_read_done
    cmp     x4, #2
    b.ne    .Lmmio_read_done
    bic     x5, x5, #(1 << 16)
#endif
    b       .Lmmio_read_done

uhs_write_hook:
    stp     x29, x30, [sp, #-16]!
    mov32   x6, SD_BASE
    sub     x7, x1, x6
    mov32   x6, UHS_STATE
    cmp     x7, #0x3E
    b.ne    1f
    cmp     x4, #1
    b.ne    .Luhs_ret
    and     w12, w5, #0xFFFF
    b       2f
1:  cmp     x7, #0x3C
    b.ne    .Luhs_clk
    cmp     x4, #2
    b.ne    .Luhs_ret
    lsr     w12, w5, #16
2:  str     w12, [x6, #4]           // w12 = new host control 2
    ldr     w13, [x6]
    tbz     w12, #3, 3f
    tbnz    w13, #0, 4f
    bl      uhs_to_1v8
4:  mov32   x6, UHS_STATE
    ldr     w13, [x6]
    and     w14, w12, #7
#if UHS_MODE == 1
    cmp     w14, #4                 // DDR50
    b.ne    5f
    tbnz    w13, #1, .Luhs_ret
    bl      uhs_ddr_on
    b       .Luhs_ret
#elif UHS_MODE == 2
    bic     w13, w13, #8
    cmp     w14, #2                 // SDR50: the host runs it as SDR104 (T210 errata), tap 11
    b.ne    17f
    orr     w13, w13, #8
    cmp     x4, #1
    b.ne    18f
    orr     x5, x5, #1              // 16-bit write: mode 2 -> 3
    b       19f
18: orr     x5, x5, #(1 << 16)      // 32-bit write at 0x3C
19: str     w13, [x6]
    bl      uhs_tap
    b       .Luhs_ret
17: str     w13, [x6]
    b       .Luhs_ret
#else
    // SDR50 (90.7 MHz, run as SDR104 per the T210 errata, 256 tuning tries) and, in mode 4,
    // SDR104 (204 MHz, 128 tries). w20 = SDMMC1 clock divider, w21 = tuning tries field.
    bic     w13, w13, #8
    cmp     w14, #2
    b.ne    21f
    mov     w20, #7
    mov     w21, #(4 << 13)
    orr     w13, w13, #8
    cmp     x4, #1
    b.ne    18f
    orr     x5, x5, #1              // 16-bit write: mode 2 -> 3
    b       19f
18: orr     x5, x5, #(1 << 16)      // 32-bit write at 0x3C
    b       19f
21:
#if UHS_MODE == 4
    cmp     w14, #3
    b.ne    17f
    mov     w20, #2                 // 408 * 2 / 4 = 204 MHz
    mov     w21, #(2 << 13)
    b       19f
#else
    b       17f
#endif
19: str     w13, [x6]
    tbz     w12, #6, 20f            // execute tuning: set up the Tegra hardware tuning
    bl      uhs_tuning
    b       .Luhs_ret
20: tbnz    w13, #1, .Luhs_ret      // fast clock already on (this is a later write)
    bl      uhs_tap
    bl      uhs_clk_fast
    b       .Luhs_ret
17: str     w13, [x6]
    tbz     w13, #1, .Luhs_ret
    bl      uhs_clk_slow
    b       .Luhs_ret
#endif
3:
#if UHS_MODE >= 2
    bic     w13, w13, #8
    str     w13, [x6]
#endif
    tbz     w13, #0, 5f             // VDD_180 cleared
    bl      uhs_to_3v3
5:  mov32   x6, UHS_STATE
    ldr     w13, [x6]
    tbz     w13, #1, .Luhs_ret
    bl      uhs_clk_off
    b       .Luhs_ret
.Luhs_clk:
    ldr     w13, [x6]
    tbz     w13, #1, .Luhs_ret      // only while DDR50 is on
    cmp     x7, #0x2F               // software reset (byte)
    b.ne    6f
    cbz     x4, 7f
    b       .Luhs_ret
6:  cmp     x7, #0x2C
    b.ne    .Luhs_ret
    cmp     x4, #2
    b.ne    8f
    tbz     w5, #24, 8f             // 32-bit write with reset all
    b       9f
7:  tbz     w5, #0, .Luhs_ret
9:  bl      uhs_clk_off
    b       .Luhs_ret
8:
#if UHS_MODE != 1
    b       .Luhs_ret               // the SDHCI divider is sdbus' own
#endif
    cbz     x4, .Luhs_ret           // clock control: divider N (bits 15:8, 7:6) 0 -> 1
    tst     w5, #0xFFC0
    b.ne    .Luhs_ret
    orr     x5, x5, #0x100
.Luhs_ret:
    ldp     x29, x30, [sp], #16
    ret

// w11 = microseconds. Clobbers w15, w16, x17.
uhs_delay:
    mov32   x17, TMR_US
    ldr     w15, [x17]
1:  ldr     w16, [x17]
    sub     w16, w16, w15
    cmp     w16, w11
    b.lo    1b
    ret

// MAX77620 LDO2 (SD I/O rail) voltage code w11 (0.8 V + 50 mV steps), power mode kept.
uhs_ldo2:
    stp     x29, x30, [sp, #-16]!
    mov     w29, w11
    mov32   x7, I2C5_BASE
    mov     w10, #20000             // let a transfer from a Windows driver finish
1:  ldr     w8, [x7, #0x1C]
    tbz     w8, #8, 2f
    subs    w10, w10, #1
    b.ne    1b
2:  mov     w6, #0x27
    mov     w9, #0
    bl      i2c5_xfer
    mov     w9, #1
    bl      i2c5_xfer
    ldr     w6, [x7, #0x0C]
    and     w6, w6, #0xC0
    orr     w6, w6, w29
    lsl     w6, w6, #8
    add     w6, w6, #0x27           // the low byte is 0 after the shift
    mov     w9, #2
    bl      i2c5_xfer
    ldp     x29, x30, [sp], #16
    ret

// Pad autocalibration (hekate _sdmmc_autocal_execute), card clock stopped by the caller.
// x8 = SD_BASE. Clobbers w9-w11, w15-w17.
uhs_autocal:
    stp     x29, x30, [sp, #-16]!
    ldr     w9, [x8, #0x1E0]
    orr     w9, w9, #(1 << 31)      // E_INPUT_PWRD
    str     w9, [x8, #0x1E0]
    ldr     w9, [x8, #0x1E0]
    mov     w11, #1
    bl      uhs_delay
    ldr     w9, [x8, #0x1E4]
    orr     w9, w9, #(1 << 29)      // enable
    orr     w9, w9, #(1 << 31)      // start
    str     w9, [x8, #0x1E4]
    ldr     w9, [x8, #0x1E4]
    mov     w11, #2
    bl      uhs_delay
    mov32   x17, TMR_US
    ldr     w15, [x17]
    mov     w11, #10000
1:  ldr     w9, [x8, #0x1EC]
    tbz     w9, #31, 2f             // done
    ldr     w16, [x17]
    sub     w16, w16, w15
    cmp     w16, w11
    b.lo    1b
    ldr     w9, [x8, #0x1E4]        // timeout: standard pad drive (50 ohm, up 8, down 8)
    bic     w9, w9, #(1 << 29)
    str     w9, [x8, #0x1E4]
    mov32   x10, 0x70000A98
    ldr     w9, [x10]
    mov32   w11, 0xF8080FFF
    and     w9, w9, w11
    mov32   w11, (0x808 << 12)
    orr     w9, w9, w11
    str     w9, [x10]
    ldr     w9, [x10]
    mov32   x10, UHS_STATE
    ldr     w9, [x10]
    orr     w9, w9, #4
    str     w9, [x10]
2:  ldr     w9, [x8, #0x1E0]
    bic     w9, w9, #(1 << 31)
    str     w9, [x8, #0x1E0]
    ldp     x29, x30, [sp], #16
    ret

uhs_to_1v8:
    stp     x29, x30, [sp, #-16]!
    mov     w11, #20                // 1.8 V
    bl      uhs_ldo2
    mov     w11, #150
    bl      uhs_delay
    mov32   x8, 0x7000E4E4          // PMC PWR_DET_VAL: SDMMC1 pads at 1.8 V
    ldr     w9, [x8]
    bic     w9, w9, #(1 << 12)
    str     w9, [x8]
    ldr     w9, [x8]
    mov32   x8, 0x70003000          // pinmux SDMMC1 CLK, CMD, DAT3..0: Schmitt trigger
    mov     x10, #0
1:  ldr     w9, [x8, x10]
    orr     w9, w9, #(1 << 12)
    str     w9, [x8, x10]
    add     x10, x10, #4
    cmp     x10, #0x18
    b.lo    1b
    mov32   x8, SD_BASE
    ldr     w14, [x8, #0x2C]        // card clock off for the calibration
    bic     w9, w14, #4
    str     w9, [x8, #0x2C]
    ldr     w9, [x8, #0x1E4]        // autocal offsets for 1.8 V: pull-down 6, pull-up 6
    mov32   w10, 0xFFFF8080
    and     w9, w9, w10
    mov     w10, #0x0606
    orr     w9, w9, w10
    str     w9, [x8, #0x1E4]
    bl      uhs_autocal
    mov     w9, #0x0B               // power control: 1.8 V, on
    strb    w9, [x8, #0x29]
    tbz     w14, #2, 2f
    ldr     w9, [x8, #0x2C]
    orr     w9, w9, #4
    str     w9, [x8, #0x2C]
2:  mov32   x10, UHS_STATE
    ldr     w9, [x10]
    orr     w9, w9, #1
    str     w9, [x10]
    ldr     w9, [x10, #12]
    add     w9, w9, #1
    str     w9, [x10, #12]
    ldp     x29, x30, [sp], #16
    ret

uhs_to_3v3:
    stp     x29, x30, [sp, #-16]!
    mov     w11, #50                // 3.3 V
    bl      uhs_ldo2
    mov     w11, #150
    bl      uhs_delay
    mov32   x8, 0x7000E4E4
    ldr     w9, [x8]
    orr     w9, w9, #(1 << 12)
    str     w9, [x8]
    ldr     w9, [x8]
    mov32   x8, SD_BASE
    ldr     w14, [x8, #0x2C]
    bic     w9, w14, #4
    str     w9, [x8, #0x2C]
    ldr     w9, [x8, #0x1E4]        // offsets for 3.3 V on T210B01: 0, 0
    mov32   w10, 0xFFFF8080
    and     w9, w9, w10
    str     w9, [x8, #0x1E4]
    bl      uhs_autocal
    mov     w9, #0x0D               // power control as UEFI leaves it (3.0 V, on)
    strb    w9, [x8, #0x29]
    tbz     w14, #2, 1f
    ldr     w9, [x8, #0x2C]
    orr     w9, w9, #4
    str     w9, [x8, #0x2C]
1:  mov32   x10, UHS_STATE
    ldr     w9, [x10]
    bic     w9, w9, #1
    str     w9, [x10]
    ldp     x29, x30, [sp], #16
    ret

// Tap 11 (T210B01) for the UHS modes, card clock stopped around it.
uhs_tap:
    mov32   x8, SD_BASE
    ldr     w14, [x8, #0x2C]
    bic     w9, w14, #4
    str     w9, [x8, #0x2C]
    ldr     w9, [x8, #0x1C0]        // tuning control 0: TAP_HW_UPDATED off
    bic     w9, w9, #(1 << 17)
    str     w9, [x8, #0x1C0]
    ldr     w9, [x8, #0x100]
    bic     w9, w9, #0xFF0000
    mov     w10, #(11 << 16)
    orr     w9, w9, w10
    str     w9, [x8, #0x100]
    str     w14, [x8, #0x2C]
    ret

// Back to 48 MHz for whichever fast clock is on.
uhs_clk_off:
#if UHS_MODE == 1
    b       uhs_ddr_off
#else
    b       uhs_clk_slow
#endif

// SDR50: SDMMC1 from PLLP with divider 7: 408 * 2 / 9 = 90.7 MHz (hekate uses 99.84 MHz from
// PLLC4, which UEFI may not have running). sdbus asks for 100 MHz from a 48 MHz base: no SDHCI
// divider, so the card gets the 90.7 MHz.
uhs_clk_fast:                       // w20 = divider
    mov     w12, w20
    mov     w13, #2
    b       1f
uhs_clk_slow:
    mov     w12, #15
    mov     w13, #0
1:  stp     x29, x30, [sp, #-16]!
    mov32   x8, SD_BASE
    ldr     w14, [x8, #0x2C]
    bic     w9, w14, #4
    str     w9, [x8, #0x2C]
    mov32   x10, (CAR_BASE + 0x150)
    ldr     w9, [x10]
    and     w9, w9, #0x1FFFFF00
    orr     w9, w9, w12
    str     w9, [x10]
    ldr     w9, [x10]
    mov     w11, #10
    bl      uhs_delay
    str     w14, [x8, #0x2C]
    mov32   x10, UHS_STATE
    ldr     w9, [x10]
    bic     w9, w9, #2
    orr     w9, w9, w13
    str     w9, [x10]
    ldp     x29, x30, [sp], #16
    ret

// sdbus starts tuning (execute tuning in host control 2, then CMD19 until the bit clears): the
// Tegra tuning setup of hekate's sdmmc_tuning_execute: w21 = tries, step 1, 1x multiplier.
uhs_tuning:
    mov32   x8, SD_BASE
    str     wzr, [x8, #0x1C4]       // ventunctl1: step size 1
    ldr     w9, [x8, #0x1C0]
    mov32   w10, 0xFFFF1FFF
    and     w9, w9, w10
    orr     w9, w9, w21         // tries: 256 (SDR50) or 128 (SDR104)
    mov32   w10, 0xFFFFE03F
    and     w9, w9, w10
    orr     w9, w9, #(1 << 6)       // 1x multiplier
    orr     w9, w9, #(1 << 17)      // TAP_HW_UPDATED
    str     w9, [x8, #0x1C0]
    ret

uhs_ddr_on:
    stp     x29, x30, [sp, #-16]!
    mov32   x8, SD_BASE
    ldr     w14, [x8, #0x2C]
    bic     w9, w14, #4
    str     w9, [x8, #0x2C]
    ldr     w9, [x8, #0x1C0]        // tuning control 0: TAP_HW_UPDATED off
    bic     w9, w9, #(1 << 17)
    str     w9, [x8, #0x1C0]
    ldr     w9, [x8, #0x100]        // vendor clock control: tap 11, the old value saved
    mov32   x10, UHS_STATE
    str     w9, [x10, #8]
    bic     w9, w9, #0xFF0000
    mov     w10, #(11 << 16)
    orr     w9, w9, w10
    str     w9, [x8, #0x100]
    mov32   x10, (CAR_BASE + 0x150) // PLLP, divider 8: 408 * 2 / 10 = 81.6 MHz
    ldr     w9, [x10]
    and     w9, w9, #0x1FFFFF00
    orr     w9, w9, #8
    str     w9, [x10]
    ldr     w9, [x10]
    mov     w11, #10
    bl      uhs_delay
    tst     w14, #0xFFC0            // SDHCI divider at least 2
    b.ne    1f
    orr     w14, w14, #0x100
1:  str     w14, [x8, #0x2C]
    mov32   x10, UHS_STATE
    ldr     w9, [x10]
    orr     w9, w9, #2
    str     w9, [x10]
    ldp     x29, x30, [sp], #16
    ret

uhs_ddr_off:
    stp     x29, x30, [sp, #-16]!
    mov32   x8, SD_BASE
    ldr     w14, [x8, #0x2C]
    bic     w9, w14, #4
    str     w9, [x8, #0x2C]
    mov32   x10, UHS_STATE
    ldr     w9, [x10, #8]           // vendor clock control as before
    str     w9, [x8, #0x100]
    mov32   x10, (CAR_BASE + 0x150) // back to 48 MHz (divider 15)
    ldr     w9, [x10]
    and     w9, w9, #0x1FFFFF00
    orr     w9, w9, #15
    str     w9, [x10]
    ldr     w9, [x10]
    mov     w11, #10
    bl      uhs_delay
    str     w14, [x8, #0x2C]
    mov32   x10, UHS_STATE
    ldr     w9, [x10]
    bic     w9, w9, #2
    str     w9, [x10]
    ldp     x29, x30, [sp], #16
    ret
#endif


    // build.py pads the file to a multiple of 8 bytes and appends UEFI right after it.
    .balign 8
payload:
