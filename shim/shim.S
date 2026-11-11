// Прокладка bl33: первый наш код, который запускается после Hekate и BL31.
//
// Hekate кладёт файл bl33.bin по адресу 0xAA000000 и передаёт сюда управление.
// Задачи: показать цветом, что код работает, настроить UART и дальше
//   - в режиме теста (TEST_MODE=1) перейти в 32-битный режим;
//   - в режиме запуска (TEST_MODE=0) скопировать UEFI на его адрес и запустить.
//
// Цвета подобраны так, чтобы не зависеть от порядка байт R и B.

#define FB_BASE     0xF5A00000
#define FB_PIXELS   (720 * 1280)

#define GREEN       0xFF00FF00
#define MAGENTA     0xFFFF00FF
#define YELLOW_CYAN 0xFF00FFFF
#define BLACK       0xFF000000
#define TMR_US      0x60005010      // микросекундный счётчик таймера Tegra
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
// 408 МГц / (16 * 115200), как считает сам Hekate.
#define UART_DIV    221

#define UEFI_BASE   0x80110000

// Векторы EL2 остаются внутри прокладки, UEFI резервирует эту область от Windows.
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
#define HCR_TSC     (1 << 19)       // перехват SMC из EL1
#define HCR_TACR    (1 << 21)       // перехват ACTLR_EL1: сигнал от UEFI
#define SMP_TABLE   TRAP_BASE       // по 16 байт на ядро: адрес старта и context_id от Windows
#define PSCI_CPU_ON64 0xC4000003
#define PSCI_CPU_ON32 0x84000003
#define UNEXPECTED_COLOR 0xFFFF0080
#define SHIM_MAGIC  0x5357534D      // ответ UEFI на сигнал: перехват SMC включён
#define SMC_TRACE   (TRAP_BASE + 0xF10)  // счётчик вызовов для трассировки на экране
#define TRACE_Y     980
#define FIQ_COLOR   0xFF00FF00
#define SERROR_COLOR 0xFFFF00FF
#define SMC_LOG     (TRAP_BASE + 0x500)  // 32 записи по 8 байт: номер функции и x1
#define MMIO_LOG    (TRAP_BASE + 0x100)  // 64 записи по 8 байт: описание обращения и значение
#define MMIO_SHOW   36
#define MMIO_COUNT  (TRAP_BASE + 0xF20)
#define HCR_VM      (1 << 0)        // вторая ступень трансляции для EL1
#define S2_L1       0xAA0FC000      // таблицы второй ступени (зарезервированная память)
#define S2_L2       0xAA0FD000      // 1..2 ГБ блоками по 2 МБ
#define S2_L3       0xAA0FE000      // 0x70000000..0x701FFFFF страницами по 4 КБ
#define S2_BLOCK    0x7FD           // блок: Normal WB (атрибуты первой ступени главнее), RW, AF
#define S2_PAGE     0x7FF
#define S2_TRAP_IDX 0xB0            // страница 0x700B0000 (SDMMC1..4) — перехватывается
#define VTCR_VAL    0x8001305F      // T0SZ=31 (8 ГБ), старт с L1, 4 КБ, PS=36 бит, обход без кэша

.macro mov32 reg, value
    movz \reg, #((\value) & 0xFFFF)
    movk \reg, #(((\value) >> 16) & 0xFFFF), lsl #16
.endm

    .text
_start:
    b       start                   // +0x00
    .word   0                       // +0x04
    .ascii  "WPSHIM01"              // +0x08
    // +0x10: Hekate читает здесь смещение DTB. Ноль указывает на начало файла,
    // где DTB нет, и загрузчик просто ничего не будет менять.
    .word   0                       // +0x10
    .word   0                       // +0x14
payload_size:
    .quad   0                       // +0x18: заполняет build.py

start:
    msr     daifset, #0xF
    adr     x19, _start

#if CLEAN
    mov32   w0, BLACK               // Чистая загрузка: просто убираем экран Hekate.
#else
    mov32   w0, GREEN
#endif
    bl      fill_screen

#if DELAY_MS
    // Пауза перед UEFI: на Mariko прошивка BPMP после Hekate ещё калибрует память,
    // а ранний UEFI в это время случайно зависал после метки 6.
    mov32   x1, TMR_US
    ldr     w2, [x1]
    mov32   w3, (DELAY_MS * 1000)
1:  ldr     w4, [x1]
    sub     w4, w4, w2
    cmp     w4, w3
    b.lo    1b
#endif
    bl      uart_setup              // x20 = 1, если UART доступен
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
    mov32   w0, MAGENTA             // Не EL2: дальше идти нельзя.
    bl      fill_screen
    b       halt

el_ok:
#if TEST_MODE
    adr     x1, a32_code
    mov     x0, x20                 // Попадёт в r0: доступен ли UART.
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

// Таблицы второй ступени: всё отображается само на себя, кроме страницы 0x700B0000.
// Портит x9-x14.
build_s2:
    mov32   x9, S2_L1
    mov     x12, #S2_BLOCK
    str     x12, [x9]               // 0..1 ГБ
    mov32   x10, (S2_L2 | 3)
    str     x10, [x9, #8]           // 1..2 ГБ -> L2
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
// Переход в 64-битный EL1: Windows рассчитана на работу в EL1, а не в EL2.
// x1 = адрес UEFI.
enter_aarch64_el1:
    mrs     x2, midr_el1
    msr     vpidr_el2, x2
    mrs     x2, mpidr_el1
    msr     vmpidr_el2, x2
    mov32   x3, TRAP_COUNT
    str     wzr, [x3]
    mov32   x3, MMIO_COUNT
    str     wzr, [x3]
    dsb     sy
    adr     x3, trap_start
    msr     vbar_el2, x3
    // Стек обработчиков — SP_EL2: при исключении процессор берёт именно его. Без SPSel=1
    // «mov sp» мог попасть в SP_EL0, и первый же вход в обработчик зацикливался.
    msr     spsel, #1
    mov32   x3, TRAP_STACK
    mov     sp, x3
    mov32   x3, SMC_TRACE
    str     wzr, [x3]
    // SMC пока не перехватываются. Сигнал от UEFI при передаче управления ОС — чтение
    // ACTLR_EL1 (перехват TACR). HVC не подходит: ATF может запретить его (SCR_EL3.HCE).
    mov32   x2, (HCR_RW | HCR_AMO | HCR_FMO | HCR_TACR)
    msr     hcr_el2, x2
    mov32   x2, 0x33FF              // Не перехватывать FP и SIMD.
    msr     cptr_el2, x2
    msr     hstr_el2, xzr
    // MDCR_EL2: не перехватывать отладку и счётчики производительности, все счётчики — EL1.
    mrs     x2, pmcr_el0
    ubfx    x2, x2, #11, #5
    msr     mdcr_el2, x2
    mov     x2, #3                  // Доступ к счётчику и таймеру из EL1.
    msr     cnthctl_el2, x2
    msr     cntvoff_el2, xzr
    mov32   x2, 0x30C50838          // SCTLR при сбросе: MMU и кэши выключены.
    msr     sctlr_el1, x2
    mov     x2, #0x3C5              // EL1h, прерывания замаскированы.
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
    .skip   0x400                   // до векторов из EL1 (AArch64)
    b       el1_sync                // +0x400: синхронное исключение из EL1 (SMC, HVC)
    .balign 128
    b       .                       // +0x480: IRQ из EL1 (сюда не направляются)
    .balign 128
    stp     x0, x1, [sp, #-16]!     // +0x500: FIQ из EL1
    mov32   w0, FIQ_COLOR
    b       trap_paint
    .balign 128
    b       serror_note             // +0x580: SError из EL1
    .balign 128
// w0 = цвет. Каждое событие рисует новую полосу; после лимита ловушка отключается.
trap_paint:
    stp     x2, x3, [sp, #-16]!
    mov32   x1, TRAP_COUNT
    ldr     w2, [x1]
    add     w3, w2, #1
    str     w3, [x1]
    cbnz    w2, 3f
    // Первое событие: заливаем весь экран и держим цвет, чтобы его было видно.
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

// SMC (перехвачен через HCR_EL2.TSC) или HVC из EL1. Вызов уходит в ATF как есть,
// кроме PSCI CPU_ON: ATF стартует новые ядра на EL2, поэтому адрес старта подменяется
// на secondary_entry, которая понижает ядро до EL1 и переходит по адресу Windows.
el1_sync:
    stp     x4, x5, [sp, #-16]!
    mrs     x4, esr_el2
    lsr     x4, x4, #26
    cmp     x4, #0x17               // SMC из AArch64
    b.eq    1f
    cmp     x4, #0x16               // HVC из AArch64
    b.eq    1f
    cmp     x4, #0x18               // MRS/MSR: чтение ACTLR_EL1 — сигнал от UEFI
    b.eq    12f
    cmp     x4, #0x24               // обращение EL1 к перехваченной странице (вторая ступень)
    b.eq    mmio_trap
    mov32   w0, UNEXPECTED_COLOR
    bl      fill_screen
    mrs     x4, esr_el2
    bl      show_bits               // 32 бита ESR_EL2: белый = 1, чёрный = 0
    b       .
1:  stp     x6, x30, [sp, #-16]!    // x30 — регистр Windows, bl его портит
    bl      trace_mark              // красный: вызов ушёл в ATF
    // журнал: номер функции и x1 в кольцевой буфер на 32 записи
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
12: mov32   x5, S2_L1               // UEFI: Windows стартует. Вторая ступень вкл.,
    msr     vttbr_el2, x5           // перехват SMC вкл., ACTLR выкл.
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
    // Синий квадрат 24x24 слева от ряда трассировки: «пароль» получен.
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
    mov32   x0, SHIM_MAGIC          // UEFI читает ACTLR_EL1 в x0
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
2:  and     x5, x1, #0xFF           // номер ядра (Aff0)
    cmp     x5, #4
    b.hs    3f
    mov32   x4, SMP_TABLE
    add     x4, x4, x5, lsl #4
    stp     x2, x3, [x4]            // адрес и context_id от Windows
    dsb     sy
    adr     x2, secondary_entry
    mov     x3, x5                  // context для secondary_entry: номер ядра
3:  smc     #0
    stp     x6, x30, [sp, #-16]!
    bl      trace_mark_done         // зелёный: ATF ответил
    ldp     x6, x30, [sp], #16
    mrs     x5, esr_el2
    lsr     x5, x5, #26
    cmp     x5, #0x17               // после SMC вернуться за инструкцию
    b.ne    4f
    mrs     x5, elr_el2
    add     x5, x5, #4
    msr     elr_el2, x5
4:  ldp     x4, x5, [sp], #16
    eret

// Квадратик 12x12 в ряду трассировки. trace_mark берёт следующий номер и красит красным,
// trace_mark_done перекрашивает текущий в зелёный. Портит x6 (и x30 через bl), их сохраняет
// вызывающий; x7-x9 сохраняются здесь.
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
6:  stp     x7, x10, [sp, #-16]!
    stp     x8, x9, [sp, #-16]!
    mov32   x7, SMC_TRACE
    ldr     w8, [x7]
    sub     w8, w8, #1
    and     w9, w8, #31             // 32 квадратика в строке
    lsr     w8, w8, #5
    and     w8, w8, #7              // до 8 строк
    mov     w7, #16
    mul     w9, w9, w7
    add     w9, w9, #40             // x (левее — синий квадрат «пароль получен»)
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

// SError из EL1: экран не закрашивается. В верхней строке (y = 8) рисуются 32 бита ESR_EL2
// последней ошибки квадратами 12x12 (белый = 1, серый = 0), ниже — полоска-счётчик ошибок.
// Ошибка пропускается, Windows продолжает работу.
// Обращение Windows к странице 0x700B0000: выполняем его сами той же ширины и пишем в журнал.
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
    tbz     x0, #24, mmio_bad       // нет описания команды (ISV=0)
    mrs     x1, hpfar_el2
    lsr     x1, x1, #4
    lsl     x1, x1, #12
    mrs     x2, far_el2
    and     x2, x2, #0xFFF
    orr     x1, x1, x2              // физический адрес
    ubfx    x3, x0, #16, #5         // номер регистра
    ubfx    x4, x0, #22, #2         // ширина: 0=1, 1=2, 2=4, 3=8 байт
    mov     x5, xzr
    cmp     x3, #31
    b.eq    1f
    ldr     x5, [sp, x3, lsl #3]
1:  tbz     x0, #6, 5f
    cmp     x4, #0                  // запись
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
5:  cmp     x4, #0                  // чтение
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
9:  // Возможности SDMMC1 (0x40): убираем бит 28 «64-битная шина». Тогда sdbus берёт 32-битный
    // DMA и буферы ниже 4 ГБ, как в ARM32. С адресом выше 4 ГБ DMA контроллера вешал всю шину.
    mov32   x6, 0x700B0040
    cmp     x1, x6
    b.ne    13f
    and     x5, x5, #0xffffffffefffffff
13: tbnz    x0, #15, 10f            // SF: 64-битный регистр
    mov     w5, w5
10: cmp     x3, #31
    b.eq    20f
    str     x5, [sp, x3, lsl #3]
20: dsb     sy
    // журнал: (адрес & 0xFFFF) | ширина << 16 | запись << 18, затем значение
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
    // только для первой ошибки: ELR_EL2 и ELR_EL1 (младшие 32 бита) и регистры чипа для SDMMC1
    cmp     w13, #1
    b.ne    6f
    mrs     x4, elr_el2
    mov     x9, #40
    bl      row32
    mrs     x4, elr_el1
    mov     x9, #56
    bl      row32
    // журнал обращений к странице SD: общее число, затем 12 последних (описание, значение)
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
6:  // счётчик: полоска длиной min(n, 500) пикселей на y = 24
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

// Рисует 32 бита w4 (старший первым) квадратами 12x12 на строке y = x9, группами по 4 бита.
// Белый = 1, серый = 0. Портит x0, x2, x3, x5, x6, x7.
row32:
    mov     x5, #31
1:  lsr     x6, x4, x5
    and     x6, x6, #1
    mov32   w7, 0xFF404040
    cbz     x6, 2f
    mov32   w7, 0xFFFFFFFF
2:  mov     x2, #31
    sub     x2, x2, x5              // номер квадрата 0..31
    lsr     x3, x2, #2              // номер группы
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


// Рисует 32 бита x4 (старший первым) квадратами 36x36 в две строки по 16, начиная с y = 560.
show_bits:
    mov     x5, #31
1:  lsr     x6, x4, x5
    and     x6, x6, #1
    mov32   w7, 0xFF000000
    cbz     x6, 2f
    mov32   w7, 0xFFFFFFFF
2:  mov     x8, #31
    sub     x8, x8, x5              // номер квадрата 0..31
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

// Сюда ATF ставит новое ядро (EL2, AArch64, MMU выключен), x0 = номер ядра.
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
    mov32   x1, (HCR_RW | HCR_AMO | HCR_FMO | HCR_TSC)
    msr     hcr_el2, x1
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
    ldp     x2, x0, [x1]            // x2 = адрес Windows, x0 = её context_id
    msr     elr_el2, x2
    mov     x1, #0x3C5              // EL1h, прерывания замаскированы
    msr     spsr_el2, x1
    mov     x1, xzr
    mov     x2, xzr
    mov     x3, xzr
    dsb     sy
    isb
    eret
    .balign 8
trap_end:
#endif

#if TEST_MODE || CHAIN_A32
// Переход в AArch32: нижний уровень (EL1) будет 32-битным.
// x0 попадёт в r0, x1 = адрес 32-битного кода. Этот путь проверен белым экраном.
enter_aarch32:
    msr     hcr_el2, xzr
    msr     cptr_el2, xzr
    msr     hstr_el2, xzr
    // UEFI работает в EL1, поэтому даём ему доступ к таймеру.
    mov     x2, #3
    msr     cnthctl_el2, x2
    msr     cntvoff_el2, xzr
    mov32   x2, 0x00C50838          // Значение SCTLR при сбросе: MMU и кэши выключены.
    msr     sctlr_el1, x2
    mov     x2, #0x1D3              // Режим SVC, прерывания замаскированы.
    msr     spsr_el2, x2
    msr     elr_el2, x1
    dsb     sy
    isb
    eret
#endif

// w0 = цвет. Портит x1, x2.
fill_screen:
    mov32   x1, FB_BASE
    mov32   x2, FB_PIXELS
1:  str     w0, [x1], #4
    subs    x2, x2, #1
    b.ne    1b
    dsb     sy
    ret

// Обращение к UART с выключенным тактированием может подвесить шину,
// поэтому сначала спрашиваем контроллер тактирования.
uart_setup:
    mov     x20, #0
    mov32   x1, CAR_BASE
    ldr     w2, [x1, #CLK_ENB_L]
    tbz     w2, #UARTB_BIT, 9f
    ldr     w2, [x1, #RST_DEV_L]
    tbnz    w2, #UARTB_BIT, 9f

    mov32   x1, UART_BASE
    str     wzr, [x1, #UART_IER]
    mov     w2, #0x83               // DLAB + 8 бит
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
    mov     w2, #0x07               // Очистка очередей
    str     w2, [x1, #UART_FCR]
    mov     x20, #1
9:  ret

// w0 = символ. Портит x1, x2, x3.
putc:
    cbz     x20, 3f
    mov32   x1, UART_BASE
    mov32   w3, 0x100000            // Лимит ожидания: не зависать из-за UART.
1:  ldr     w2, [x1, #UART_LSR]
    tbnz    w2, #5, 2f
    subs    w3, w3, #1
    b.ne    1b
    ret
2:  str     w0, [x1, #UART_THR]
3:  ret

// x0 = строка. Портит x0-x4, сохраняет адрес возврата в x5.
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

    // build.py дополняет файл до кратного 8 байтам и дописывает UEFI сразу после.
    .balign 8
payload:
