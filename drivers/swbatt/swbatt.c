// Switch battery and temperature for Windows: a battery class miniport (battc.sys)
// plus fan control.
//
// Every POLL_MS it reads over I2C1:
//   MAX17050 (0x36): fuel gauge: percent, capacity, voltage, current, battery temperature;
//   BQ24193  (0x6B): charger: whether external power is present and charging is on;
//   TMP451   (0x4C): SoC and board temperature.
// Windows sees a regular battery: tray icon with percent, "charging", remaining time,
// and shuts itself down at BATTERY_CRITICAL (the action is set by powercfg in w32.cmd).
// Fan: off below FAN_STOP_C (40 C) until it is FAN_LOW_C (45 C) again (hysteresis), as Horizon
// keeps it quiet when cool; 50% up to FAN_LOW_C, then linear to 100% at FAN_HIGH_C (65 C); 100% if the
// temperature cannot be read. At SHUTDOWN_C and above the system is shut down.
// I2C1 is set up by UEFI (PmicDxe); no other Windows driver uses it.
// Headphone jack: every JACK_MS it also reads PV6 (the jack switch, low = plugged, Switchroot's
// realtek,jack-detect-gpios) and moves the sound between the speaker and the headphones by the
// mute bits of the ALC5639 (0x1C, also on I2C1). Only when UEFI set up the headphone path.
// USB port power (only when UEFI started the XUSB host, Mariko boards): the BM92T USB-C
// controller (0x18) reports a device that wants power (an OTG adapter); then the port is powered
// as Switchroot does (bm92txx.c, bq2419x-charger.c, tegra210b01 device trees): the 5.3 V
// source (GPIO PX3), VCONN (PK5) and the charger in VBUS mode at 1.3 A, with the BM92T's own
// over-current protection on. Everything is switched back when the device is removed, on a
// charger boost fault and when the driver stops.
// GPU power bridge: the experimental GM20B driver of mesa-switch-woa reaches the GPU rail through
// \Device\SwitchBacklight (IOCTL 0x222410, struct tg_gpu_pmic_request, as winx's SwitchFan
// serves it on the Lite). Served here, kernel callers only, and narrowed to what that driver
// needs: reads of the MAX77812 (0x31/0x33); writes only to M1 (the GPU rail): its voltage
// (0x23) between 0.6 and 1.05 V and its enable bit in EN_CTRL (0x06), never M3 (DRAM) or M4
// (CPU). I2C5 is shared with swhid through a named synchronization event.
#include <ntddk.h>
#include <batclass.h>

// Exported by ntoskrnl.lib but not declared in the WDK headers.
NTSYSAPI NTSTATUS NTAPI ZwInitiatePowerAction(POWER_ACTION SystemAction,
    SYSTEM_POWER_STATE LightestSystemState, ULONG Flags, BOOLEAN Asynchronous);
#ifndef POWER_ACTION_OVERRIDE_APPS
#define POWER_ACTION_OVERRIDE_APPS 0x00000004
#endif
#ifndef POWER_ACTION_CRITICAL
#define POWER_ACTION_CRITICAL 0x80000000
#endif

#define I2C1_BASE       0x7000C000ULL
#define I2C_SIZE        0x100
#define PWM_BASE        0x7000A000ULL
#define PWM_SIZE        0x100
#define PWM_FAN_CSR     (0x10 / 4)
#define PWM_ENABLE      0x80000000UL
#define FAN_DUTY_MAX    236

#define ADDR_GAUGE      0x36
#define ADDR_CHARGER    0x6B
#define ADDR_TEMP       0x4C
#define ADDR_CODEC      0x1C
#define CODEC_SPK_VOL   0x01
#define CODEC_HP_VOL    0x02
#define CODEC_HPO_MIXER 0x45
#define CODEC_HPVOL_MUTED (1 << 13)    // HPO MIX input from HPOVOL muted: no headphone path
#define CODEC_MUTE      0x8080
#define GPIO_BASE       0x6000D000ULL
#define GPIO_SIZE       0x1000
#define GPIO_PV_CNF     (0x504 / 4)     // bank 5, port V
#define GPIO_PV_OE      (0x514 / 4)
#define GPIO_PV_IN      (0x534 / 4)
#define PV6             (1 << 6)
#define JACK_MS         250

#define G_TEMP          0x08
#define G_REPSOC        0x06
#define G_VCELL         0x09
#define G_CURRENT       0x0A
#define G_AVGCURRENT    0x0B
#define G_FULLCAP       0x10
#define G_TTE           0x11
#define G_DESIGNCAP     0x18
#define G_TTF           0x20
#define CHG_SYS_STATUS  0x08
#define T_LOCAL         0x00
#define T_REMOTE        0x01
#define T_REMOTE_FRAC   0x10

#define POLL_MS         5000
#define LOG_EVERY       12          // once a minute
#define DESIGN_MWH      16400       // 4310 mAh x 3.8 V
#define CRITICAL_PCT    3
#define FAN_MIN_PCT     50
#define FAN_LOW_C       45
#define FAN_STOP_C      40
#define FAN_HIGH_C      65
#define SHUTDOWN_C      85
#define READ_FAIL_FAN   3
#define HOT_READINGS    3           // this many polls in a row above SHUTDOWN_C
#define PLAUSIBLE_MAX_C 125

#define R_CNFG          (0x00 / 4)
#define R_CMD_ADDR0     (0x04 / 4)
#define R_CMD_DATA1     (0x0C / 4)
#define R_STATUS        (0x1C / 4)
#define R_CONFIG_LOAD   (0x8C / 4)
#define R_TX_FIFO       (0x50 / 4)
#define R_RX_FIFO       (0x54 / 4)
#define R_PKT_STATUS    (0x58 / 4)
#define R_FIFO_CONTROL  (0x5C / 4)
#define R_FIFO_STATUS   (0x60 / 4)
#define PACKET_GO       (1 << 10)
#define FIFO_FLUSH      3
#define RX_FIFO_COUNT   0xF
#define PROT_I2C        (1 << 4)
#define HDR_REP_START   (1 << 16)
#define HDR_READ        (1 << 19)
#define ADDR0_READ      1
#define CMD1_READ       (1 << 6)
#define NORMAL_GO       (1 << 9)
#define NEW_MASTER_FSM  (1 << 11)
#define DEBOUNCE_4T     (2 << 12)
#define STATUS_NOACK    0xF
#define STATUS_BUSY     (1 << 8)
#define LOAD_ALL        ((1 << 5) | (1 << 2) | 1)
#define MASTER_LOAD     1
#define POLL_US         10
#define POLL_LIMIT      20000

#define LOG_SIZE        8192
#define BATTERY_TAG     1

DRIVER_INITIALIZE DriverEntry;
DRIVER_ADD_DEVICE AddDevice;
DRIVER_UNLOAD Unload;
KSTART_ROUTINE PollThread;
_Dispatch_type_(IRP_MJ_PNP) DRIVER_DISPATCH DispatchPnp;
_Dispatch_type_(IRP_MJ_POWER) DRIVER_DISPATCH DispatchPower;
_Dispatch_type_(IRP_MJ_DEVICE_CONTROL) DRIVER_DISPATCH DispatchIoctl;
_Dispatch_type_(IRP_MJ_CREATE) _Dispatch_type_(IRP_MJ_CLOSE) DRIVER_DISPATCH DispatchCreateClose;
_Dispatch_type_(IRP_MJ_SYSTEM_CONTROL) DRIVER_DISPATCH DispatchPassDown;

typedef struct _SNAPSHOT {
    BOOLEAN valid;
    BOOLEAN online;
    BOOLEAN charging;
    ULONG percent100;       // percent x 100
    ULONG fullMwh;
    ULONG millivolts;
    LONG milliamps;         // < 0: discharging
    LONG batteryDeciC;      // battery temperature, tenths of C
    ULONG tteSeconds;
    LONG socDeciC;          // SoC, tenths of C
    LONG pcbC;
    ULONG fanPct;
    UCHAR chargerStatus;
} SNAPSHOT;

typedef struct _DEVICE_EXTENSION {
    PDEVICE_OBJECT self;
    PDEVICE_OBJECT pdo;
    PDEVICE_OBJECT lower;
    PVOID classData;
    BOOLEAN started;
} DEVICE_EXTENSION, *PDEVICE_EXTENSION;

static volatile ULONG *g_i2c;
static volatile ULONG *g_pwm;
static volatile ULONG *g_gpio;
static BOOLEAN g_jack;
static KEVENT g_stop;
static PVOID g_thread;
static FAST_MUTEX g_snapLock;
static SNAPSHOT g_snap;
static PDEVICE_EXTENSION g_ext;
static CHAR g_log[LOG_SIZE];
static ULONG g_len;

// ---- I2C1, normal mode: up to 4 bytes per transaction ----------------------------------

static VOID LoadConfig(VOID)
{
    g_i2c[R_CONFIG_LOAD] = LOAD_ALL;
    for (ULONG i = 0; i < 20 && (g_i2c[R_CONFIG_LOAD] & MASTER_LOAD); i++)
        KeStallExecutionProcessor(1);
}

static BOOLEAN Transfer(UCHAR addr, BOOLEAN read, ULONG *data, ULONG size)
{
    ULONG poll;

    g_i2c[R_CMD_ADDR0] = ((ULONG) addr << 1) | (read ? ADDR0_READ : 0);
    if (!read)
        g_i2c[R_CMD_DATA1] = *data;
    g_i2c[R_CNFG] = ((size - 1) << 1) | DEBOUNCE_4T | NEW_MASTER_FSM | (read ? CMD1_READ : 0);
    LoadConfig();
    g_i2c[R_CNFG] = (g_i2c[R_CNFG] & ~NORMAL_GO) | NORMAL_GO;
    for (poll = 0; g_i2c[R_STATUS] & STATUS_BUSY; poll++) {
        if (poll == POLL_LIMIT)
            return FALSE;
        KeStallExecutionProcessor(POLL_US);
    }
    if (g_i2c[R_STATUS] & STATUS_NOACK)
        return FALSE;
    if (read)
        *data = g_i2c[R_CMD_DATA1];
    return TRUE;
}

static BOOLEAN ReadReg(UCHAR addr, UCHAR reg, ULONG size, ULONG *value)
{
    ULONG pointer = reg;

    return Transfer(addr, FALSE, &pointer, 1) && Transfer(addr, TRUE, value, size);
}

static BOOLEAN Gauge(UCHAR reg, ULONG *value)
{
    if (!ReadReg(ADDR_GAUGE, reg, 2, value))
        return FALSE;
    *value &= 0xFFFF;
    return TRUE;
}

// Division by a variable without the kernel library helper (it needs a GS cookie).
static ULONG UDiv(ULONG n, ULONG d)
{
    ULONG q = 0;

    if (d == 0)
        return 0;
    for (LONG bit = 31; bit >= 0; bit--) {
        if ((n >> bit) >= d) {
            n -= d << bit;
            q |= 1UL << bit;
        }
    }
    return q;
}

// ---- Log in C:\swagent\bat.txt (latest entries, older ones are dropped) ----------------------------------------------------

static VOID LogText(const CHAR *text)
{
    while (*text != 0 && g_len < LOG_SIZE - 1)
        g_log[g_len++] = *text++;
}

static VOID LogNum(LONG value)
{
    CHAR digits[12];
    ULONG n = 0;
    ULONG v;

    if (value < 0) {
        LogText("-");
        v = (ULONG) -value;
    } else {
        v = (ULONG) value;
    }
    do {
        digits[n++] = (CHAR) ('0' + v % 10);
        v /= 10;
    } while (v != 0 && n < sizeof(digits));
    while (n > 0 && g_len < LOG_SIZE - 1)
        g_log[g_len++] = digits[--n];
}

static VOID LogPair(const CHAR *name, LONG value)
{
    LogText(name);
    LogText("=");
    LogNum(value);
    LogText(" ");
}

static VOID SaveLog(VOID)
{
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES attributes;
    IO_STATUS_BLOCK io;
    HANDLE file;

    RtlInitUnicodeString(&name, L"\\??\\C:\\swagent\\bat.txt");
    InitializeObjectAttributes(&attributes, &name, OBJ_KERNEL_HANDLE | OBJ_CASE_INSENSITIVE, NULL, NULL);
    if (NT_SUCCESS(ZwCreateFile(&file, GENERIC_WRITE | SYNCHRONIZE, &attributes, &io, NULL,
            FILE_ATTRIBUTE_NORMAL, 0, FILE_OVERWRITE_IF, FILE_SYNCHRONOUS_IO_NONALERT, NULL, 0))) {
        ZwWriteFile(file, NULL, NULL, NULL, &io, g_log, g_len, NULL, NULL);
        ZwFlushBuffersFile(file, &io);
        ZwClose(file);
    }
}

// ---- Fan ---------------------------------------------------------------------------

static VOID SetFan(ULONG percent)
{
    ULONG duty = percent * FAN_DUTY_MAX / 100;

    // PWM polarity is inverted, as in UEFI (FanStart). 0%: bit 24, "absolute 0%" in hekate's
    // fan_set_duty (the 5 V fan supply stays on, so the fan can start again at once).
    g_pwm[PWM_FAN_CSR] = PWM_ENABLE | ((percent == 0 ? 0x100 : FAN_DUTY_MAX - duty) << 16);
}

static ULONG FanForTemp(LONG socC)
{
    static BOOLEAN stopped;

    if (socC < FAN_STOP_C)
        stopped = TRUE;
    else if (socC >= FAN_LOW_C)
        stopped = FALSE;
    if (stopped)
        return 0;
    if (socC <= FAN_LOW_C)
        return FAN_MIN_PCT;
    if (socC >= FAN_HIGH_C)
        return 100;
    return FAN_MIN_PCT + (ULONG) (socC - FAN_LOW_C) * (100 - FAN_MIN_PCT) / (FAN_HIGH_C - FAN_LOW_C);
}

// ---- Polling -----------------------------------------------------------------------

static BOOLEAN ReadSnapshot(SNAPSHOT *s, ULONG raw[8])
{
    ULONG soc, vcell, current, fullcap, design, temp, tte, chg, tHigh, tFrac, tLocal;
    BOOLEAN gaugeOk, chargerOk;

    RtlZeroMemory(s, sizeof(*s));
    gaugeOk = Gauge(G_REPSOC, &soc) && Gauge(G_VCELL, &vcell) && Gauge(G_AVGCURRENT, &current) &&
              Gauge(G_FULLCAP, &fullcap) && Gauge(G_DESIGNCAP, &design) && Gauge(G_TEMP, &temp) &&
              Gauge(G_TTE, &tte);
    chargerOk = ReadReg(ADDR_CHARGER, CHG_SYS_STATUS, 1, &chg);

    if (ReadReg(ADDR_TEMP, T_REMOTE, 1, &tHigh) && ReadReg(ADDR_TEMP, T_REMOTE_FRAC, 1, &tFrac)) {
        s->socDeciC = (LONG) (tHigh & 0xFF) * 10 + (LONG) ((tFrac & 0xF0) >> 4) * 10 / 16;
    } else {
        s->socDeciC = -1;
    }
    s->pcbC = ReadReg(ADDR_TEMP, T_LOCAL, 1, &tLocal) ? (LONG) (tLocal & 0xFF) : -1;

    raw[0] = soc; raw[1] = vcell; raw[2] = current; raw[3] = fullcap;
    raw[4] = design; raw[5] = temp; raw[6] = tte; raw[7] = chg;
    if (!gaugeOk)
        return FALSE;

    s->valid = TRUE;
    s->percent100 = soc * 100 / 256;
    if (s->percent100 > 10000)
        s->percent100 = 10000;
    s->millivolts = vcell * 5 / 64;                                // 0.078125 mV per unit
    s->milliamps = (LONG) (SHORT) current * 5 / 32;               // 1.5625 uV / 10 mOhm (checked against the discharge rate)
    s->batteryDeciC = (LONG) (SHORT) temp * 10 / 256;
    s->tteSeconds = tte * 45 / 8;                                  // 5.625 s per unit
    s->fullMwh = DESIGN_MWH;
    if (design != 0 && fullcap != 0 && fullcap < design)
        s->fullMwh = UDiv(DESIGN_MWH * fullcap, design);
    if (chargerOk) {
        s->chargerStatus = (UCHAR) chg;
        s->online = (chg & (1 << 2)) != 0 && ((chg >> 6) & 3) != 3;   // PG_STAT, not OTG mode
        s->charging = s->online && ((chg >> 4) & 3) != 0 && ((chg >> 4) & 3) != 3;
    } else {
        s->online = s->milliamps > 0;
        s->charging = s->online;
    }
    return TRUE;
}

static VOID Shutdown(VOID)
{
    // Same as a critical battery: Windows closes everything and shuts down.
    (VOID) ZwInitiatePowerAction(PowerActionShutdownOff, PowerSystemShutdown,
        POWER_ACTION_CRITICAL | POWER_ACTION_OVERRIDE_APPS, TRUE);
}

// Read-only access to the clock registers, to log the current CPU and memory clocks.
static VOID LogHex8(ULONG value)
{
    static const CHAR digits[] = "0123456789ABCDEF";
    CHAR text[9];

    for (ULONG i = 0; i < 8; i++)
        text[i] = digits[(value >> (28 - i * 4)) & 0xF];
    text[8] = 0;
    LogText(text);
}

// ---- EL2 shim counters, read from its reserved page (shim/shim.S: TRAP_BASE) -----------------
// MMIO_COUNT (0xF20): SD register accesses the shim has trapped; UHS_STATE (0xF30): flags
// (1 = 1.8 V, 2 = fast clock, 4 = autocal timeout, 8 = SDR50 as SDR104), last host control 2,
// saved vendor clock control, voltage switches; HANDOFF_PMIC (0xF40): PMIC LDO6 and LDO2 configs
// when UEFI handed over to Windows (0x100 | value). The page is read only when it is not memory
// Windows manages (MmGetPhysicalMemoryRanges), so mapping it uncached cannot clash with the OS.

#define SHIM_PAGE 0xAA0FF000ULL

static BOOLEAN g_shimChecked;
static BOOLEAN g_shimOk;
static ULONG g_shimLastCount;
static ULONGLONG g_shimLastTime;

static BOOLEAN ShimPageIsReserved(VOID)
{
    PPHYSICAL_MEMORY_RANGE ranges = MmGetPhysicalMemoryRanges();
    BOOLEAN reserved = TRUE;

    if (ranges == NULL)
        return FALSE;
    for (ULONG i = 0; ranges[i].BaseAddress.QuadPart != 0 || ranges[i].NumberOfBytes.QuadPart != 0; i++) {
        ULONGLONG base = (ULONGLONG) ranges[i].BaseAddress.QuadPart;
        if (SHIM_PAGE + 0x1000 > base && SHIM_PAGE < base + (ULONGLONG) ranges[i].NumberOfBytes.QuadPart)
            reserved = FALSE;
    }
    ExFreePool(ranges);
    return reserved;
}

static VOID LogShim(VOID)
{
    PHYSICAL_ADDRESS address;
    volatile ULONG *page;
    ULONG count, flags, hostctl2, switches, ldo6, ldo2;
    ULONGLONG now;

    if (!g_shimChecked) {
        g_shimChecked = TRUE;
        g_shimOk = ShimPageIsReserved();
        if (!g_shimOk)
            LogText("shim: page is Windows memory, counters not read\r\n");
    }
    if (!g_shimOk)
        return;
    address.QuadPart = (LONGLONG) SHIM_PAGE;
    page = MmMapIoSpace(address, 0x1000, MmNonCached);
    if (page == NULL)
        return;
    count = page[0xF20 / 4];
    flags = page[0xF30 / 4];
    hostctl2 = page[0xF34 / 4];
    switches = page[0xF3C / 4];
    ldo6 = page[0xF40 / 4];
    ldo2 = page[0xF44 / 4];
    MmUnmapIoSpace((PVOID) page, 0x1000);
    now = KeQueryInterruptTime();

    LogText("shim: sd_traps=");
    LogHex8(count);
    if (g_shimLastTime != 0 && now > g_shimLastTime) {
        LogText(" per_s=");
        LogNum((LONG) ((ULONGLONG) (count - g_shimLastCount) * 10000000ULL / (now - g_shimLastTime)));
    }
    g_shimLastCount = count;
    g_shimLastTime = now;
    LogText(" uhs=");
    LogHex8(flags);
    LogText(" hostctl2=");
    LogHex8(hostctl2);
    LogText(" v_switches=");
    LogNum((LONG) switches);
    LogText(" handoff_ldo6=");
    LogHex8(ldo6);
    LogText(" handoff_ldo2=");
    LogHex8(ldo2);
    LogText("\r\n");
}

// Display controller (DC A, 0x54200000) as UEFI left it: the registers mesa-switch-woa's WDDM
// display driver compares with the Switch Lite's panel before it takes over the boot framebuffer
// (platform/t214_dc.c, tg_t214_dc_has_boot_mode). Read once at start, reads only.
// Black-box area: 0xAA0F0000, inside the shim's reserved 1 MB (0xAA000000) but above the loaded
// bl33 image and below its stage-2 tables, so neither Hekate, the shim nor UEFI writes it and
// Windows does not manage it. This checks whether its contents survive a reboot: a header
// (magic, boot counter) and a 4 KB pattern derived from the counter; the count of wrong bits
// tells how well DRAM kept it. Then a new header and pattern are written for the next boot.
#define BLACKBOX_PAGE  0xAA0F0000ULL
#define BLACKBOX_MAGIC 0x58425753u      // "SWBX"
#define BLACKBOX_WORDS 1024

static VOID LogHex8(ULONG value);

static ULONG BlackboxPattern(ULONG seed, ULONG i)
{
    ULONG x = seed * 2654435761u + i * 40503u + 0x9E3779B9u;
    x ^= x >> 15; x *= 0x2C1B3C6Du; x ^= x >> 12;
    return x;
}

static VOID LogBlackbox(VOID)
{
    PHYSICAL_ADDRESS address;
    volatile ULONG *box;
    ULONG count, bad = 0, i;

    if (!ShimPageIsReserved())          // same check: the page must not be Windows memory
        return;
    address.QuadPart = (LONGLONG) BLACKBOX_PAGE;
    box = MmMapIoSpace(address, 0x2000, MmNonCached);
    if (box == NULL)
        return;
    LogText("blackbox: ");
    if (box[0] == BLACKBOX_MAGIC) {
        count = box[1];
        for (i = 0; i < BLACKBOX_WORDS; i++) {
            ULONG diff = box[16 + i] ^ BlackboxPattern(count, i);
            while (diff) { bad += diff & 1; diff >>= 1; }
        }
        LogText("kept from boot ");
        LogNum((LONG) count);
        LogText(", wrong bits ");
        LogNum((LONG) bad);
        LogText(" of 32768, word2=");
        LogHex8(box[2]);
    } else {
        LogText("no header (word0=");
        LogHex8(box[0]);
        LogText(")");
        count = 0;
    }
    count++;
    for (i = 0; i < BLACKBOX_WORDS; i++)
        box[16 + i] = BlackboxPattern(count, i);
    box[2] = (ULONG) (KeQueryInterruptTime() / 10000);
    box[1] = count;
    box[0] = BLACKBOX_MAGIC;
    KeMemoryBarrier();
    LogText(", now boot ");
    LogNum((LONG) count);
    LogText("\r\n");
    MmUnmapIoSpace((PVOID) box, 0x2000);
}

// PMC scratch candidates for a black box (APBDEV_PMC_SCRATCH190..193, PMC 0x7000E400 + 0x818):
// no use found in hekate or Linux. Log what they hold at start (someone else's data, or our
// label from the previous boot if they survive a reboot), then write a label for the next boot.
static VOID LogPmcScratch(VOID)
{
    PHYSICAL_ADDRESS address;
    volatile ULONG *pmc;
    ULONG count;

    address.QuadPart = 0x7000E000LL;
    pmc = MmMapIoSpace(address, 0x1000, MmNonCached);
    if (pmc == NULL)
        return;
    volatile ULONG *scratch = pmc + (0x400 + 0x818) / 4;
    LogText("pmcscratch190-193:");
    for (ULONG i = 0; i < 4; i++) {
        LogText(" ");
        LogHex8(scratch[i]);
    }
    LogText(" scratch0=");
    LogHex8(pmc[(0x400 + 0x50) / 4]);
    count = scratch[0] == BLACKBOX_MAGIC ? scratch[1] + 1 : 1;
    scratch[1] = count;
    scratch[2] = (ULONG) (KeQueryInterruptTime() / 10000);
    scratch[3] = ~count;
    scratch[0] = BLACKBOX_MAGIC;
    (VOID) scratch[0];
    LogText(scratch[0] == BLACKBOX_MAGIC && scratch[1] == count ? " -> label written, boot " : " -> write did not stick, boot ");
    LogNum((LONG) count);
    LogText("\r\n");
    MmUnmapIoSpace((PVOID) pmc, 0x1000);
}

static VOID LogHex4(ULONG value);

static VOID LogDisplay(VOID)
{
    static const USHORT words[] = { 0x032, 0x402, 0x407, 0x408, 0x409, 0x40a, 0xb80, 0xb81, 0xb82,
        0xb83, 0xb84, 0xb85, 0xb86, 0xb87, 0xb88, 0xb89, 0xb8a, 0xbc0, 0xbc6, 0xbc8, 0xbcb, 0xbcd };
    PHYSICAL_ADDRESS address;
    volatile ULONG *dc;

    address.QuadPart = 0x54200000ULL;
    dc = MmMapIoSpace(address, 0x4000, MmNonCached);
    if (dc == NULL)
        return;
    LogText("dc");
    for (ULONG i = 0; i < sizeof(words) / sizeof(words[0]); i++) {
        LogText(" ");
        LogHex4(words[i]);
        LogText("=");
        LogHex8(dc[words[i]]);
    }
    LogText("\r\n");
    MmUnmapIoSpace((PVOID) dc, 0x4000);
}

static VOID LogClocks(VOID)
{
    static const USHORT regs[] = { 0x020, 0x024, 0x0E0, 0x0E4, 0x0E8, 0x090, 0x094, 0x5E8, 0x19C, 0x370, 0x374 };
    PHYSICAL_ADDRESS address;
    volatile ULONG *car;

    address.QuadPart = 0x60006000ULL;
    car = MmMapIoSpace(address, 0x1000, MmNonCached);
    if (car == NULL)
        return;
    LogText("clocks");
    for (ULONG i = 0; i < sizeof(regs) / sizeof(regs[0]); i++) {
        LogText(" ");
        LogNum(regs[i]);
        LogText("=");
        LogNum((LONG) car[regs[i] / 4]);
    }
    MmUnmapIoSpace((PVOID) car, 0x1000);
    address.QuadPart = 0x70000000ULL;
    car = MmMapIoSpace(address, 0x1000, MmNonCached);
    if (car != NULL) {
        LogText(" hidrev=");                    // bits 7:4: 1 = T210 (Erista), 2 = T210B01 (Mariko)
        LogNum((LONG) car[0x804 / 4]);
        MmUnmapIoSpace((PVOID) car, 0x1000);
    }
    // SDMMC1 clock source in the CAR (the SD controller's own registers are not read here:
    // that page goes through the shim's trap and is left to sdbus).
    address.QuadPart = 0x60006000ULL;
    car = MmMapIoSpace(address, 0x1000, MmNonCached);
    if (car != NULL) {
        LogText(" sd_clk_src=");
        LogHex8(car[0x150 / 4]);
        MmUnmapIoSpace((PVOID) car, 0x1000);
    }
    // CPU voltage: MAX77812 regulator (I2C5, 0x31 or 0x33), register M4_VOUT, read only.
    address.QuadPart = 0x7000D000ULL;
    car = MmMapIoSpace(address, I2C_SIZE, MmNonCached);
    if (car != NULL && g_i2c != NULL) {
        volatile ULONG *i2c1 = g_i2c;
        ULONG vout;

        g_i2c = car;
        for (UCHAR addr = 0x31; addr <= 0x33; addr += 2) {
            if (ReadReg(addr, 0x26, 1, &vout)) {
                LogText(addr == 0x31 ? " cpu_mV@31=" : " cpu_mV@33=");
                LogNum((LONG) (250 + (vout & 0xFF) * 5));
            }
        }
        g_i2c = i2c1;
    }
    if (car != NULL)
        MmUnmapIoSpace((PVOID) car, I2C_SIZE);
    LogText("\r\n");
}

// ---- Headphone jack ---------------------------------------------------------------

// rt5640 registers: 8-bit address, 16-bit big-endian value.
static BOOLEAN CodecRead(UCHAR reg, ULONG *value)
{
    ULONG raw;

    if (!ReadReg(ADDR_CODEC, reg, 2, &raw))
        return FALSE;
    *value = ((raw & 0xFF) << 8) | ((raw >> 8) & 0xFF);
    return TRUE;
}

static BOOLEAN CodecMute(UCHAR reg, BOOLEAN mute)
{
    ULONG value, data;

    if (!CodecRead(reg, &value))
        return FALSE;
    value = mute ? (value | CODEC_MUTE) : (value & ~CODEC_MUTE);
    data = reg | ((value >> 8) << 8) | ((value & 0xFF) << 16);
    return Transfer(ADDR_CODEC, FALSE, &data, 3);
}

// ---- GPU power bridge ---------------------------------------------------------------

#define BRIDGE_IOCTL        0x00222410u     // CTL_CODE(0x22, 0x904, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define BRIDGE_QUERY_ADDRESS 0x100u
#define BRIDGE_QUERY_PLLP   0x101u
#define BRIDGE_QUERY_TEMP   0x102u
#define I2C5_PHYS           0x7000D000ULL
#define GPU_PMIC_EN_CTRL    0x06
#define GPU_PMIC_M1_VOUT    0x23
#define GPU_PMIC_M1_EN      0x01
#define GPU_M1_MIN          70              // 250 mV + 70 * 5 mV = 0.60 V
#define GPU_M1_MAX          160             // 1.05 V, the driver's own limit

typedef struct {
    ULONG address;
    ULONG reg;
    ULONG write;
    ULONG value;
} BRIDGE_REQUEST;

static PDEVICE_OBJECT g_bridge;
static volatile ULONG *g_i2c5;
static PKEVENT g_i2c5Lock;
static HANDLE g_i2c5LockHandle;
static UCHAR g_gpuPmic;                     // 0x31 or 0x33 once found
static volatile LONG g_socC = 255;          // last SoC temperature, 255 = unknown

// The same named event as swhid: one I2C5 user at a time. A wait that times out (another driver
// stuck) proceeds and is logged rather than blocking the caller for good.
static VOID I2c5Lock(VOID)
{
    LARGE_INTEGER timeout;

    timeout.QuadPart = -10000LL * 200;
    if (g_i2c5Lock != NULL &&
            KeWaitForSingleObject(g_i2c5Lock, Executive, KernelMode, FALSE, &timeout) == STATUS_TIMEOUT)
        LogText("bridge: i2c5 lock timeout\r\n");
}

static VOID I2c5Unlock(VOID)
{
    if (g_i2c5Lock != NULL)
        KeSetEvent(g_i2c5Lock, IO_NO_INCREMENT, FALSE);
}

static BOOLEAN P5Xfer(UCHAR addr, BOOLEAN read, ULONG *data, ULONG size)
{
    ULONG poll;

    g_i2c5[0x04 / 4] = ((ULONG) addr << 1) | (read ? 1 : 0);
    if (!read)
        g_i2c5[0x0C / 4] = *data;
    g_i2c5[0x00 / 4] = ((size - 1) << 1) | (2 << 12) | (1 << 11) | (read ? (1 << 6) : 0);
    g_i2c5[0x8C / 4] = (1 << 5) | (1 << 2) | 1;
    for (poll = 0; poll < 20 && (g_i2c5[0x8C / 4] & 1); poll++)
        KeStallExecutionProcessor(1);
    g_i2c5[0x00 / 4] |= 1 << 9;
    for (poll = 0; g_i2c5[0x1C / 4] & (1 << 8); poll++) {
        if (poll == 20000)
            return FALSE;
        KeStallExecutionProcessor(10);
    }
    if (g_i2c5[0x1C / 4] & 0xF)
        return FALSE;
    if (read)
        *data = g_i2c5[0x0C / 4];
    return TRUE;
}

static BOOLEAN PmicRead(UCHAR addr, UCHAR reg, UCHAR *value)
{
    ULONG data = reg;
    BOOLEAN ok;

    if (g_i2c5 == NULL)
        return FALSE;
    I2c5Lock();
    ok = P5Xfer(addr, FALSE, &data, 1) && P5Xfer(addr, TRUE, &data, 1);
    I2c5Unlock();
    if (ok)
        *value = (UCHAR) data;
    return ok;
}

static BOOLEAN PmicWrite(UCHAR addr, UCHAR reg, UCHAR value)
{
    ULONG data = reg | ((ULONG) value << 8);
    BOOLEAN ok;

    if (g_i2c5 == NULL)
        return FALSE;
    I2c5Lock();
    ok = P5Xfer(addr, FALSE, &data, 2);
    I2c5Unlock();
    return ok;
}

static VOID LogGpu(const CHAR *what, ULONG reg, ULONG value)
{
    static const CHAR digits[] = "0123456789ABCDEF";
    CHAR text[8];

    LogText("bridge: ");
    LogText(what);
    text[0] = ' ';
    text[1] = digits[(reg >> 4) & 0xF];
    text[2] = digits[reg & 0xF];
    text[3] = '=';
    text[4] = digits[(value >> 4) & 0xF];
    text[5] = digits[value & 0xF];
    text[6] = 0;
    LogText(text);
    LogText("\r\n");
    SaveLog();
}

static NTSTATUS BridgeRequest(BRIDGE_REQUEST *r)
{
    UCHAR value, now;

    if (r->address == 0) {
        switch (r->reg) {
        case BRIDGE_QUERY_ADDRESS:
            if (g_gpuPmic == 0) {
                BOOLEAN at31 = PmicRead(0x31, GPU_PMIC_M1_VOUT, &value);
                BOOLEAN at33 = PmicRead(0x33, GPU_PMIC_M1_VOUT, &value);
                if (at31 == at33)
                    return STATUS_DEVICE_NOT_READY;
                g_gpuPmic = at31 ? 0x31 : 0x33;
                LogGpu("pmic", 0, g_gpuPmic);
            }
            r->value = g_gpuPmic;
            return STATUS_SUCCESS;
        case BRIDGE_QUERY_TEMP:
            r->value = (ULONG) g_socC;
            return STATUS_SUCCESS;
        case BRIDGE_QUERY_PLLP: {
            PHYSICAL_ADDRESS address;
            volatile ULONG *car;

            address.QuadPart = 0x60006000ULL;
            car = MmMapIoSpace(address, 0x100, MmNonCached);
            if (car == NULL)
                return STATUS_INSUFFICIENT_RESOURCES;
            r->value = car[0xA0 / 4];
            MmUnmapIoSpace((PVOID) car, 0x100);
            return STATUS_SUCCESS;
        }
        default:
            return STATUS_INVALID_PARAMETER;
        }
    }
    if (g_gpuPmic == 0 || r->address != g_gpuPmic || r->reg > 0xFF)
        return STATUS_ACCESS_DENIED;
    if (!r->write) {
        if (!PmicRead(g_gpuPmic, (UCHAR) r->reg, &value))
            return STATUS_IO_DEVICE_ERROR;
        r->value = value;
        return STATUS_SUCCESS;
    }
    if (r->value > 0xFF)
        return STATUS_INVALID_PARAMETER;
    if (r->reg == GPU_PMIC_M1_VOUT) {
        if (r->value < GPU_M1_MIN || r->value > GPU_M1_MAX) {
            LogGpu("refused M1 voltage", r->reg, r->value);
            return STATUS_ACCESS_DENIED;
        }
    } else if (r->reg == GPU_PMIC_EN_CTRL) {
        // Only the M1 enable bit may change; M2-M4 (DRAM, CPU) keep their current state.
        if (!PmicRead(g_gpuPmic, GPU_PMIC_EN_CTRL, &now))
            return STATUS_IO_DEVICE_ERROR;
        if (((now ^ r->value) & ~GPU_PMIC_M1_EN) != 0) {
            LogGpu("refused EN_CTRL", r->reg, r->value);
            return STATUS_ACCESS_DENIED;
        }
    } else {
        LogGpu("refused write", r->reg, r->value);
        return STATUS_ACCESS_DENIED;
    }
    if (!PmicWrite(g_gpuPmic, (UCHAR) r->reg, (UCHAR) r->value))
        return STATUS_IO_DEVICE_ERROR;
    LogGpu("write", r->reg, r->value);
    return STATUS_SUCCESS;
}

// IRP_MJ_CREATE/CLOSE and IRP_MJ_DEVICE_CONTROL on the bridge device. User-mode opens are refused.
static NTSTATUS BridgeDispatch(PIRP irp)
{
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(irp);
    NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;

    irp->IoStatus.Information = 0;
    if (stack->MajorFunction == IRP_MJ_CREATE) {
        status = irp->RequestorMode == KernelMode ? STATUS_SUCCESS : STATUS_ACCESS_DENIED;
    } else if (stack->MajorFunction == IRP_MJ_CLOSE || stack->MajorFunction == IRP_MJ_CLEANUP) {
        status = STATUS_SUCCESS;
    } else if (stack->MajorFunction == IRP_MJ_DEVICE_CONTROL &&
            stack->Parameters.DeviceIoControl.IoControlCode == BRIDGE_IOCTL &&
            irp->RequestorMode == KernelMode) {
        if (stack->Parameters.DeviceIoControl.InputBufferLength < sizeof(BRIDGE_REQUEST) ||
                stack->Parameters.DeviceIoControl.OutputBufferLength < sizeof(BRIDGE_REQUEST)) {
            status = STATUS_BUFFER_TOO_SMALL;
        } else {
            status = BridgeRequest((BRIDGE_REQUEST *) irp->AssociatedIrp.SystemBuffer);
            if (NT_SUCCESS(status))
                irp->IoStatus.Information = sizeof(BRIDGE_REQUEST);
        }
    }
    irp->IoStatus.Status = status;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return status;
}

static VOID BridgeStart(PDRIVER_OBJECT driver)
{
    UNICODE_STRING name, lockName;
    PHYSICAL_ADDRESS address;

    RtlInitUnicodeString(&lockName, L"\\BaseNamedObjects\\SwitchWoaI2c5");
    g_i2c5Lock = IoCreateSynchronizationEvent(&lockName, &g_i2c5LockHandle);
    address.QuadPart = I2C5_PHYS;
    g_i2c5 = MmMapIoSpace(address, 0x100, MmNonCached);
    RtlInitUnicodeString(&name, L"\\Device\\SwitchBacklight");
    if (g_i2c5 == NULL || !NT_SUCCESS(IoCreateDevice(driver, 0, &name, FILE_DEVICE_UNKNOWN,
            FILE_DEVICE_SECURE_OPEN, FALSE, &g_bridge)))
        g_bridge = NULL;
    else
        g_bridge->Flags &= ~DO_DEVICE_INITIALIZING;
}

static VOID BridgeStop(VOID)
{
    if (g_bridge != NULL)
        IoDeleteDevice(g_bridge);
    g_bridge = NULL;
    if (g_i2c5 != NULL)
        MmUnmapIoSpace((PVOID) g_i2c5, 0x100);
    g_i2c5 = NULL;
    if (g_i2c5LockHandle != NULL)
        ZwClose(g_i2c5LockHandle);
    g_i2c5LockHandle = NULL;
    g_i2c5Lock = NULL;
}

// ---- USB port power ----------------------------------------------------------------

#define ADDR_PD         0x18            // BM92T36 USB-C / power delivery controller
#define PD_STATUS1      0x03
#define PD_STATUS2      0x04
#define PD_CONFIG1      0x06
#define PD_VENDOR_CONFIG 0x1A
#define PD_FW_TYPE      0x4B
#define PD_FW_REV       0x4C
#define PD_FW_TYPE_OK   0x0603
#define PD_S1_INSERT    (1u << 7)
#define PD_S1_SRC_MODE  (1u << 12)     // the console is the power source
#define PD_S2_OTG       (1u << 13)
#define PD_CONFIG1_SPDSRC (3u << 14)   // 0: both VBUS source switches may close
#define PD_VENDOR_OCP_OFF (1u << 2)
#define CHG_PWR_ON      0x01
#define CHG_TIMER       0x05
#define CHG_FAULT       0x09
#define CHG_REVISION    0x0A
#define CHG_REVISION_OK 0x2F
#define CHG_MODE_MASK   0x30
#define CHG_MODE_VBUS   0x20
#define CHG_BOOST_1300  0x01
#define CHG_WATCHDOG    0x30
#define CHG_BOOST_FAULT 0x40
#define CAR_RST_DEV_U   (0x00C / 4)    // as the _STA of ACPI XHC0: host out of reset, clock on
#define CAR_ENB_U       (0x018 / 4)
#define CAR_XUSB_HOST   (1u << 25)
#define PINMUX_BASE     0x70003000ULL
#define PINMUX_PX3      (0x228 / 4)    // 5.3 V VBUS source enable
#define PINMUX_PK5      (0x268 / 4)    // VCONN enable
#define PINMUX_PULL_DOWN (1u << 2)
#define GPIO_PX_CNF     (0x50C / 4)
#define GPIO_PX_OE      (0x51C / 4)
#define GPIO_PX_OUT     (0x52C / 4)
#define PX3             (1u << 3)
#define GPIO_PK_CNF     (0x208 / 4)
#define GPIO_PK_OE      (0x218 / 4)
#define GPIO_PK_OUT     (0x228 / 4)
#define PK5             (1u << 5)

static BOOLEAN g_usb;                   // port power may be switched
static BOOLEAN g_vbus;                  // port powered now
static BOOLEAN g_vbusFault;             // boost fault: off until the device is removed
static ULONG g_chgSaved;                // charger REG01 before VBUS mode

static VOID LogHex4(ULONG value)
{
    static const CHAR digits[] = "0123456789ABCDEF";
    CHAR text[6];

    for (ULONG i = 0; i < 4; i++)
        text[i] = digits[(value >> (12 - i * 4)) & 0xF];
    text[4] = ' ';
    text[5] = 0;
    LogText(text);
}

// The BM92T needs a repeated start between the register write and the read (a stop resets its
// register pointer and the read returns zeros): packet mode, as the touch driver and hekate do.
static BOOLEAN PdRead(UCHAR reg, ULONG *value)
{
    ULONG addr = ADDR_PD << 1, poll;
    BOOLEAN ok = FALSE;

    g_i2c[R_CMD_ADDR0] = addr | ADDR0_READ;
    g_i2c[R_CNFG] = DEBOUNCE_4T | NEW_MASTER_FSM | CMD1_READ;
    g_i2c[R_FIFO_CONTROL] = FIFO_FLUSH;
    LoadConfig();
    g_i2c[R_CNFG] = (g_i2c[R_CNFG] & ~NORMAL_GO) | PACKET_GO;
    g_i2c[R_TX_FIFO] = PROT_I2C;
    g_i2c[R_TX_FIFO] = 0;
    g_i2c[R_TX_FIFO] = HDR_REP_START | addr;
    g_i2c[R_TX_FIFO] = reg;
    g_i2c[R_TX_FIFO] = PROT_I2C;
    g_i2c[R_TX_FIFO] = 1;                       // two bytes
    g_i2c[R_TX_FIFO] = HDR_READ | addr;
    for (poll = 0; poll < POLL_LIMIT; poll++) {
        if (g_i2c[R_STATUS] & STATUS_NOACK)
            break;
        if (g_i2c[R_FIFO_STATUS] & RX_FIFO_COUNT) {
            *value = g_i2c[R_RX_FIFO] & 0xFFFF;
            ok = TRUE;
            break;
        }
        KeStallExecutionProcessor(POLL_US);
    }
    if (g_i2c[R_STATUS] & STATUS_NOACK)
        ok = FALSE;
    KeStallExecutionProcessor(20);
    g_i2c[R_CNFG] &= ~(PACKET_GO | NORMAL_GO);
    return ok;
}

static BOOLEAN PdWrite(UCHAR reg, ULONG value)
{
    ULONG data = reg | ((value & 0xFF) << 8) | ((value >> 8) << 16);

    return Transfer(ADDR_PD, FALSE, &data, 3);
}

static BOOLEAN ChgRead(UCHAR reg, ULONG *value)
{
    if (!ReadReg(ADDR_CHARGER, reg, 1, value))
        return FALSE;
    *value &= 0xFF;
    return TRUE;
}

static BOOLEAN ChgWrite(UCHAR reg, ULONG value)
{
    ULONG data = reg | ((value & 0xFF) << 8), back;

    return Transfer(ADDR_CHARGER, FALSE, &data, 2) && ChgRead(reg, &back) && back == (value & 0xFF);
}

// The two enable pins as GPIO outputs, low. Pin settings from Switchroot's pinmux tables.
static VOID UsbPins(BOOLEAN on)
{
    if (on) {
        g_gpio[GPIO_PX_OUT] |= PX3;
        KeStallExecutionProcessor(10000);      // regulator ramp, as its device tree node says
        g_gpio[GPIO_PK_OUT] |= PK5;
    } else {
        g_gpio[GPIO_PK_OUT] &= ~PK5;
        g_gpio[GPIO_PX_OUT] &= ~PX3;
    }
}

static VOID UsbPowerOff(VOID)
{
    ULONG value;

    if (!g_vbus)
        return;
    // Charger back to its previous mode and the 500 mA boost limit, then the supplies off.
    if (!ChgWrite(CHG_PWR_ON, g_chgSaved & ~CHG_BOOST_1300))
        LogText("usb: charger restore FAILED\r\n");
    UsbPins(FALSE);
    g_vbus = FALSE;
    LogText("usb: port power off, charger ");
    if (ChgRead(CHG_PWR_ON, &value))
        LogHex4(value);
    LogText("\r\n");
    SaveLog();
}

static VOID UsbPowerOn(VOID)
{
    ULONG timer, value;

    if (!ChgRead(CHG_PWR_ON, &g_chgSaved) || !ChgRead(CHG_TIMER, &timer)) {
        LogText("usb: charger read FAILED, no port power\r\n");
        return;
    }
    // Nothing serves the charger watchdog here: with it on, the charger would drop VBUS mode
    // after 40 s (Switchroot: ti,watchdog-timeout = 0).
    if ((timer & CHG_WATCHDOG) && !ChgWrite(CHG_TIMER, timer & ~CHG_WATCHDOG)) {
        LogText("usb: charger watchdog FAILED, no port power\r\n");
        return;
    }
    UsbPins(TRUE);
    if (!ChgWrite(CHG_PWR_ON, (g_chgSaved & ~CHG_MODE_MASK) | CHG_MODE_VBUS | CHG_BOOST_1300)) {
        LogText("usb: charger VBUS mode FAILED\r\n");
        ChgWrite(CHG_PWR_ON, g_chgSaved);
        UsbPins(FALSE);
        return;
    }
    g_vbus = TRUE;
    LogText("usb: port power on, charger ");
    LogHex4(g_chgSaved);
    if (ChgRead(CHG_PWR_ON, &value))
        LogHex4(value);
    LogText("\r\n");
    SaveLog();
}

// Once at start: only with the XUSB host running, a known BM92T and a known charger.
// ---- Charger input current from the USB-C power contract ------------------------------------
// The BQ24193 picks its input current limit itself when a source is plugged in: 500 mA for a
// computer port (VBUS_STAT "USB host"). That is less than Windows draws, so the battery ran down on a
// Mac's USB-C port. Horizon raises the limit after the BM92T has a power contract; here the
// limit is raised to what the source itself offers in the current PD contract (CURRENT_PDO,
// fixed supply), at most 2 A, never above it. Without a contract nothing is changed.

#define PD_CURRENT_PDO  0x28
#define CHG_INPUT       0x00
#define CHG_IINLIM_MASK 0x07

static ULONG g_pdo;                     // last CURRENT_PDO (0 = none)
static ULONG g_chgInput = 0xFFFFFFFF;   // last REG00 read

// BM92T register of up to 8 bytes (the first is its length), repeated start as in PdRead.
static BOOLEAN PdReadBytes(UCHAR reg, UCHAR *buf, ULONG n)
{
    ULONG addr = ADDR_PD << 1, poll, words = (n + 3) / 4, got = 0;
    BOOLEAN ok = FALSE;

    g_i2c[R_CMD_ADDR0] = addr | ADDR0_READ;
    g_i2c[R_CNFG] = DEBOUNCE_4T | NEW_MASTER_FSM | CMD1_READ;
    g_i2c[R_FIFO_CONTROL] = FIFO_FLUSH;
    LoadConfig();
    g_i2c[R_CNFG] = (g_i2c[R_CNFG] & ~NORMAL_GO) | PACKET_GO;
    g_i2c[R_TX_FIFO] = PROT_I2C;
    g_i2c[R_TX_FIFO] = 0;
    g_i2c[R_TX_FIFO] = HDR_REP_START | addr;
    g_i2c[R_TX_FIFO] = reg;
    g_i2c[R_TX_FIFO] = PROT_I2C;
    g_i2c[R_TX_FIFO] = n - 1;
    g_i2c[R_TX_FIFO] = HDR_READ | addr;
    for (poll = 0; poll < POLL_LIMIT && got < words; poll++) {
        if (g_i2c[R_STATUS] & STATUS_NOACK)
            break;
        if (g_i2c[R_FIFO_STATUS] & RX_FIFO_COUNT) {
            ULONG w = g_i2c[R_RX_FIFO];
            for (ULONG i = 0; i < 4 && got * 4 + i < n; i++)
                buf[got * 4 + i] = (UCHAR) (w >> (8 * i));
            got++;
            continue;
        }
        KeStallExecutionProcessor(POLL_US);
    }
    ok = got == words && !(g_i2c[R_STATUS] & STATUS_NOACK);
    KeStallExecutionProcessor(20);
    g_i2c[R_CNFG] &= ~(PACKET_GO | NORMAL_GO);
    return ok;
}

static VOID ChargePoll(VOID)
{
    static ULONG lastSet = 0xFFFFFFFF;
    UCHAR b[5];
    ULONG s1, input, pdo = 0, ma, mv, step;

    if (g_vbus)                         // the console powers the port: no input
        return;
    if (!ChgRead(CHG_INPUT, &input))
        return;
    g_chgInput = input;
    if (!g_usb)                         // BM92T not recognised at start: do not use it
        return;
    if (!PdRead(PD_STATUS1, &s1) || (s1 & (PD_S1_INSERT | PD_S1_SRC_MODE)) != PD_S1_INSERT) {
        g_pdo = 0;
        return;
    }
    if (PdReadBytes(PD_CURRENT_PDO, b, 5) && b[0] >= 4)
        pdo = b[1] | ((ULONG) b[2] << 8) | ((ULONG) b[3] << 16) | ((ULONG) b[4] << 24);
    g_pdo = pdo;
    if (pdo == 0 || (pdo >> 30) != 0)  // no contract, or not a fixed supply
        return;
    ma = (pdo & 0x3FF) * 10;
    mv = ((pdo >> 10) & 0x3FF) * 50;
    if (mv < 4750 || mv > 15500)
        return;
    step = ma >= 2000 ? 6 : ma >= 1500 ? 5 : ma >= 1200 ? 4 : ma >= 900 ? 3 : 0;
    if (step == 0 || (input & CHG_IINLIM_MASK) >= step)
        return;
    if (ChgWrite(CHG_INPUT, (input & ~CHG_IINLIM_MASK) | step)) {
        g_chgInput = (input & ~CHG_IINLIM_MASK) | step;
        if (lastSet != pdo) {
            lastSet = pdo;
            LogText("charge: contract ");
            LogNum((LONG) mv);
            LogText(" mV ");
            LogNum((LONG) ma);
            LogText(" mA, input limit ");
            LogHex8(input);
            LogText(" -> ");
            LogHex8(g_chgInput);
            LogText("\r\n");
        }
    }
}

static VOID UsbStart(VOID)
{
    PHYSICAL_ADDRESS address;
    volatile ULONG *car, *pinmux;
    ULONG type = 0, rev = 0, config = 0, vendor = 0, chg = 0;
    BOOLEAN host;

    g_usb = FALSE;
    if (g_gpio == NULL)
        return;
    address.QuadPart = 0x60006000ULL;
    car = MmMapIoSpace(address, 0x100, MmNonCached);
    if (car == NULL)
        return;
    host = !(car[CAR_RST_DEV_U] & CAR_XUSB_HOST) && (car[CAR_ENB_U] & CAR_XUSB_HOST);
    MmUnmapIoSpace((PVOID) car, 0x100);
    if (!host) {
        LogText("usb: host not started, port power not used\r\n");
        return;
    }
    if (!PdRead(PD_FW_TYPE, &type) || !PdRead(PD_FW_REV, &rev) || !PdRead(PD_CONFIG1, &config) ||
            !PdRead(PD_VENDOR_CONFIG, &vendor) || !ChgRead(CHG_REVISION, &chg)) {
        LogText("usb: BM92T or charger read FAILED, port power not used\r\n");
        return;
    }
    LogText("usb: bm92t type/rev/config1/vendor ");
    LogHex4(type);
    LogHex4(rev);
    LogHex4(config);
    LogHex4(vendor);
    LogText("charger rev ");
    LogHex4(chg);
    LogText("\r\n");
    if (type != PD_FW_TYPE_OK || chg != CHG_REVISION_OK) {
        LogText("usb: unknown BM92T or charger, port power not used\r\n");
        return;
    }
    // Over-current protection on, both source switches allowed: verified by reading back.
    if ((vendor & PD_VENDOR_OCP_OFF) && (!PdWrite(PD_VENDOR_CONFIG, vendor & ~PD_VENDOR_OCP_OFF) ||
            !PdRead(PD_VENDOR_CONFIG, &vendor) || (vendor & PD_VENDOR_OCP_OFF))) {
        LogText("usb: over-current protection not set, port power not used\r\n");
        return;
    }
    if ((config & PD_CONFIG1_SPDSRC) && (!PdWrite(PD_CONFIG1, config & ~PD_CONFIG1_SPDSRC) ||
            !PdRead(PD_CONFIG1, &config) || (config & PD_CONFIG1_SPDSRC))) {
        LogText("usb: source mode not set, port power not used\r\n");
        return;
    }
    address.QuadPart = PINMUX_BASE;
    pinmux = MmMapIoSpace(address, 0x1000, MmNonCached);
    if (pinmux == NULL)
        return;
    LogText("usb: pins px3/pk5 pinmux ");
    LogHex4(pinmux[PINMUX_PX3]);
    LogHex4(pinmux[PINMUX_PK5]);
    LogText("out ");
    LogHex4(((g_gpio[GPIO_PX_OUT] & PX3) ? 0x10 : 0) | ((g_gpio[GPIO_PK_OUT] & PK5) ? 1 : 0));
    LogText("\r\n");
    // Outputs, low, before the pads drive them.
    g_gpio[GPIO_PX_OUT] &= ~PX3;
    g_gpio[GPIO_PX_OE] |= PX3;
    g_gpio[GPIO_PX_CNF] |= PX3;
    g_gpio[GPIO_PK_OUT] &= ~PK5;
    g_gpio[GPIO_PK_OE] |= PK5;
    g_gpio[GPIO_PK_CNF] |= PK5;
    pinmux[PINMUX_PX3] = PINMUX_PULL_DOWN;          // rsvd0, pull-down, driven, no input
    pinmux[PINMUX_PK5] = PINMUX_PULL_DOWN | 1;      // rsvd1, pull-down, driven, no input
    MmUnmapIoSpace((PVOID) pinmux, 0x1000);
    g_usb = TRUE;
    LogText("usb: port power ready\r\n");
}

// Every JACK_MS. Power on after 4 equal "device wants power" readings (1 s), off after 2
// readings without it or a failed read.
static VOID UsbPoll(VOID)
{
    static ULONG wants, gone;
    ULONG s1, s2, fault;
    BOOLEAN ok, device;

    if (!g_usb)
        return;
    ok = PdRead(PD_STATUS1, &s1) && PdRead(PD_STATUS2, &s2);
    device = ok && (s1 & (PD_S1_INSERT | PD_S1_SRC_MODE)) == (PD_S1_INSERT | PD_S1_SRC_MODE) &&
        (s2 & PD_S2_OTG);
    if (device) {
        gone = 0;
        if (!g_vbus && !g_vbusFault && ++wants == 4) {
            LogText("usb: device, status ");
            LogHex4(s1);
            LogHex4(s2);
            LogText("\r\n");
            UsbPowerOn();
        }
        if (g_vbus && ChgRead(CHG_FAULT, &fault) && (fault & CHG_BOOST_FAULT)) {
            LogText("usb: charger boost fault\r\n");
            g_vbusFault = TRUE;
            UsbPowerOff();
        }
        return;
    }
    wants = 0;
    if (++gone >= 2) {
        g_vbusFault = FALSE;
        UsbPowerOff();
    }
}

// Only when UEFI set up the headphone path and left PV6 a GPIO input.
static VOID JackStart(VOID)
{
    PHYSICAL_ADDRESS address;
    ULONG hpo = 0;

    g_jack = FALSE;
    address.QuadPart = GPIO_BASE;
    g_gpio = MmMapIoSpace(address, GPIO_SIZE, MmNonCached);
    if (g_gpio == NULL || !(g_gpio[GPIO_PV_CNF] & PV6) || (g_gpio[GPIO_PV_OE] & PV6) ||
            !CodecRead(CODEC_HPO_MIXER, &hpo) || (hpo & CODEC_HPVOL_MUTED)) {
        LogText("jack: off\r\n");
        return;
    }
    g_jack = TRUE;
    LogText("jack: on\r\n");
}

// Two equal readings make a change; the first stable reading applies the current state too.
static VOID JackPoll(VOID)
{
    static LONG last = -1, applied = -1;
    LONG plugged;

    if (!g_jack)
        return;
    plugged = (g_gpio[GPIO_PV_IN] & PV6) ? 0 : 1;
    if (plugged != last) {
        last = plugged;
        return;
    }
    if (plugged == applied)
        return;
    if (CodecMute(CODEC_SPK_VOL, plugged != 0) && CodecMute(CODEC_HP_VOL, plugged == 0)) {
        applied = plugged;
        LogText(plugged ? "jack: headphones\r\n" : "jack: speaker\r\n");
        SaveLog();
    }
}

VOID PollThread(PVOID context)
{
    LARGE_INTEGER delay;
    SNAPSHOT s, old;
    ULONG raw[8];
    ULONG tick = 0;
    ULONG tempFails = 0;
    BOOLEAN shutdownSent = FALSE;
    ULONG hot = 0;

    ULONG pass = 0;

    UNREFERENCED_PARAMETER(context);
    // The loop runs every JACK_MS for the jack; the battery and fan part every POLL_MS.
    delay.QuadPart = -10000LL * JACK_MS;
    RtlZeroMemory(&old, sizeof(old));
    LogClocks();
    LogDisplay();
    LogBlackbox();
    LogPmcScratch();
    JackStart();
    UsbStart();
    SaveLog();

    do {
        JackPoll();
        UsbPoll();
        if (pass % (POLL_MS / JACK_MS) == 0)
            ChargePoll();
        if (pass++ % (POLL_MS / JACK_MS) != 0)
            continue;
        BOOLEAN ok = ReadSnapshot(&s, raw);

        if (s.socDeciC < 0) {
            tempFails++;
            s.fanPct = tempFails >= READ_FAIL_FAN ? 100 : old.fanPct ? old.fanPct : FAN_MIN_PCT;
        } else {
            tempFails = 0;
            s.fanPct = FanForTemp(s.socDeciC / 10);
        }
        if (s.fanPct != old.fanPct)
            SetFan(s.fanPct);

        ExAcquireFastMutex(&g_snapLock);
        g_snap = s;
        InterlockedExchange(&g_socC, s.socDeciC >= 0 ? s.socDeciC / 10 : 255);
        ExReleaseFastMutex(&g_snapLock);

        if (g_ext != NULL && g_ext->classData != NULL &&
                (s.valid != old.valid || s.online != old.online || s.charging != old.charging ||
                 s.percent100 / 100 != old.percent100 / 100))
            BatteryClassStatusNotify(g_ext->classData);

        if (tick % LOG_EVERY == 0) {
            if (g_len > LOG_SIZE / 2) {
                RtlMoveMemory(g_log, g_log + LOG_SIZE / 4, g_len - LOG_SIZE / 4);
                g_len -= LOG_SIZE / 4;
            }
            LogText("t=");
            LogNum((LONG) (tick * POLL_MS / 1000));
            LogText(" ");
            LogText(ok ? "gauge=ok " : "gauge=FAIL ");
            LogPair("pct100", s.percent100);
            LogPair("mV", s.millivolts);
            LogPair("mA", s.milliamps);
            LogPair("fullmWh", s.fullMwh);
            LogPair("batt_dC", s.batteryDeciC);
            LogPair("tte_s", s.tteSeconds);
            LogPair("online", s.online);
            LogPair("charging", s.charging);
            LogPair("soc_dC", s.socDeciC);
            LogPair("pcb_C", s.pcbC);
            LogPair("fan", s.fanPct);
            LogText("\r\nraw");
            for (ULONG i = 0; i < 8; i++) {
                LogText(" ");
                LogNum((LONG) raw[i]);
            }
            LogText("\r\n");
            LogText("charge: input=");
            LogHex8(g_chgInput);
            LogText(" pdo=");
            LogHex8(g_pdo);
            LogText("\r\n");
            LogShim();
            SaveLog();
        }

        if (s.socDeciC >= SHUTDOWN_C * 10 && s.socDeciC < PLAUSIBLE_MAX_C * 10)
            hot++;
        else
            hot = 0;
        if (!shutdownSent && hot >= HOT_READINGS) {
            shutdownSent = TRUE;
            LogText("OVERHEAT soc_dC=");
            LogNum(s.socDeciC);
            LogText(" shutting down\r\n");
            SaveLog();
            Shutdown();
        }
        old = s;
        tick++;
    } while (KeWaitForSingleObject(&g_stop, Executive, KernelMode, FALSE, &delay) == STATUS_TIMEOUT);

    UsbPowerOff();
    SetFan(FAN_MIN_PCT);
    PsTerminateSystemThread(STATUS_SUCCESS);
}

// ---- Battery class -----------------------------------------------------------------

static NTSTATUS QueryTag(PVOID context, PULONG tag)
{
    UNREFERENCED_PARAMETER(context);
    *tag = BATTERY_TAG;
    return STATUS_SUCCESS;
}

static NTSTATUS ReturnBuffer(PVOID buffer, ULONG length, PULONG returned, const VOID *data, ULONG size)
{
    *returned = size;
    if (length < size)
        return STATUS_BUFFER_TOO_SMALL;
    RtlCopyMemory(buffer, data, size);
    return STATUS_SUCCESS;
}

static NTSTATUS QueryInformation(PVOID context, ULONG tag, BATTERY_QUERY_INFORMATION_LEVEL level,
    LONG atRate, PVOID buffer, ULONG length, PULONG returned)
{
    static const WCHAR name[] = L"Switch battery";
    static const WCHAR maker[] = L"Nintendo";
    BATTERY_INFORMATION info;
    SNAPSHOT s;
    ULONG value;

    UNREFERENCED_PARAMETER(context);
    UNREFERENCED_PARAMETER(atRate);
    if (tag != BATTERY_TAG)
        return STATUS_NO_SUCH_DEVICE;
    ExAcquireFastMutex(&g_snapLock);
    s = g_snap;
    ExReleaseFastMutex(&g_snapLock);

    switch (level) {
    case BatteryInformation:
        RtlZeroMemory(&info, sizeof(info));
        info.Capabilities = BATTERY_SYSTEM_BATTERY;
        info.Technology = 1;
        RtlCopyMemory(info.Chemistry, "LION", 4);
        info.DesignedCapacity = DESIGN_MWH;
        info.FullChargedCapacity = s.fullMwh ? s.fullMwh : DESIGN_MWH;
        info.DefaultAlert1 = info.FullChargedCapacity * 7 / 100;
        info.DefaultAlert2 = info.FullChargedCapacity * CRITICAL_PCT / 100;
        info.CriticalBias = 0;
        info.CycleCount = 0;
        return ReturnBuffer(buffer, length, returned, &info, sizeof(info));
    case BatteryTemperature:
        value = (ULONG) (s.batteryDeciC + 2732);    // tenths of a kelvin
        return ReturnBuffer(buffer, length, returned, &value, sizeof(value));
    case BatteryEstimatedTime:
        value = (s.valid && !s.online && s.tteSeconds != 0 && s.tteSeconds < 0xFFFF * 6)
            ? s.tteSeconds : BATTERY_UNKNOWN_TIME;
        return ReturnBuffer(buffer, length, returned, &value, sizeof(value));
    case BatteryDeviceName:
        return ReturnBuffer(buffer, length, returned, name, sizeof(name));
    case BatteryManufactureName:
        return ReturnBuffer(buffer, length, returned, maker, sizeof(maker));
    default:
        return STATUS_INVALID_DEVICE_REQUEST;
    }
}

static NTSTATUS QueryStatus(PVOID context, ULONG tag, PBATTERY_STATUS status)
{
    SNAPSHOT s;

    UNREFERENCED_PARAMETER(context);
    if (tag != BATTERY_TAG)
        return STATUS_NO_SUCH_DEVICE;
    ExAcquireFastMutex(&g_snapLock);
    s = g_snap;
    ExReleaseFastMutex(&g_snapLock);

    RtlZeroMemory(status, sizeof(*status));
    if (!s.valid) {
        status->PowerState = BATTERY_POWER_ON_LINE;
        status->Capacity = BATTERY_UNKNOWN_CAPACITY;
        status->Voltage = BATTERY_UNKNOWN_VOLTAGE;
        status->Rate = BATTERY_UNKNOWN_RATE;
        return STATUS_SUCCESS;
    }
    if (s.online)
        status->PowerState |= BATTERY_POWER_ON_LINE;
    if (s.charging)
        status->PowerState |= BATTERY_CHARGING;
    if (!s.online) {
        status->PowerState |= BATTERY_DISCHARGING;
        if (s.percent100 <= CRITICAL_PCT * 100)
            status->PowerState |= BATTERY_CRITICAL;
    }
    status->Capacity = s.fullMwh * s.percent100 / 10000;
    status->Voltage = s.millivolts;
    status->Rate = s.milliamps * (LONG) s.millivolts / 1000;        // mW, < 0: discharging
    return STATUS_SUCCESS;
}

static NTSTATUS SetInformation(PVOID context, ULONG tag, BATTERY_SET_INFORMATION_LEVEL level, PVOID buffer)
{
    UNREFERENCED_PARAMETER(context);
    UNREFERENCED_PARAMETER(tag);
    UNREFERENCED_PARAMETER(level);
    UNREFERENCED_PARAMETER(buffer);
    return STATUS_NOT_SUPPORTED;
}

static NTSTATUS SetStatusNotify(PVOID context, ULONG tag, PBATTERY_NOTIFY notify)
{
    // Polling already reports changes every POLL_MS.
    UNREFERENCED_PARAMETER(context);
    UNREFERENCED_PARAMETER(notify);
    return tag == BATTERY_TAG ? STATUS_SUCCESS : STATUS_NO_SUCH_DEVICE;
}

static NTSTATUS DisableStatusNotify(PVOID context)
{
    UNREFERENCED_PARAMETER(context);
    return STATUS_SUCCESS;
}

// ---- Device ------------------------------------------------------------------------

static NTSTATUS StartPolling(VOID)
{
    PHYSICAL_ADDRESS address;
    HANDLE handle;
    NTSTATUS status;

    if (g_thread != NULL)
        return STATUS_SUCCESS;
    address.QuadPart = I2C1_BASE;
    g_i2c = MmMapIoSpace(address, I2C_SIZE, MmNonCached);
    address.QuadPart = PWM_BASE;
    g_pwm = MmMapIoSpace(address, PWM_SIZE, MmNonCached);
    if (g_i2c == NULL || g_pwm == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;

    KeClearEvent(&g_stop);
    status = PsCreateSystemThread(&handle, THREAD_ALL_ACCESS, NULL, NULL, NULL, PollThread, NULL);
    if (NT_SUCCESS(status)) {
        ObReferenceObjectByHandle(handle, THREAD_ALL_ACCESS, NULL, KernelMode, &g_thread, NULL);
        ZwClose(handle);
    }
    return status;
}

static VOID StopPolling(VOID)
{
    if (g_thread != NULL) {
        KeSetEvent(&g_stop, IO_NO_INCREMENT, FALSE);
        KeWaitForSingleObject(g_thread, Executive, KernelMode, FALSE, NULL);
        ObDereferenceObject(g_thread);
        g_thread = NULL;
    }
    if (g_i2c != NULL)
        MmUnmapIoSpace((PVOID) g_i2c, I2C_SIZE);
    if (g_pwm != NULL)
        MmUnmapIoSpace((PVOID) g_pwm, PWM_SIZE);
    if (g_gpio != NULL)
        MmUnmapIoSpace((PVOID) g_gpio, GPIO_SIZE);
    g_i2c = NULL;
    g_pwm = NULL;
    g_gpio = NULL;
    g_jack = FALSE;
}

static NTSTATUS CompleteIrp(PIRP irp, NTSTATUS status)
{
    irp->IoStatus.Status = status;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return status;
}

static NTSTATUS StartCompletion(PDEVICE_OBJECT device, PIRP irp, PVOID context)
{
    UNREFERENCED_PARAMETER(device);
    UNREFERENCED_PARAMETER(irp);
    KeSetEvent((PKEVENT) context, IO_NO_INCREMENT, FALSE);
    return STATUS_MORE_PROCESSING_REQUIRED;
}

static NTSTATUS StartDevice(PDEVICE_EXTENSION ext)
{
    BATTERY_MINIPORT_INFO info;
    NTSTATUS status;

    status = StartPolling();
    if (!NT_SUCCESS(status))
        return status;
    RtlZeroMemory(&info, sizeof(info));
    info.MajorVersion = BATTERY_CLASS_MAJOR_VERSION;
    info.MinorVersion = BATTERY_CLASS_MINOR_VERSION;
    info.Context = ext;
    info.QueryTag = QueryTag;
    info.QueryInformation = QueryInformation;
    info.SetInformation = SetInformation;
    info.QueryStatus = QueryStatus;
    info.SetStatusNotify = SetStatusNotify;
    info.DisableStatusNotify = DisableStatusNotify;
    info.Pdo = ext->pdo;
    info.DeviceName = NULL;
    status = BatteryClassInitializeDevice(&info, &ext->classData);
    if (NT_SUCCESS(status))
        ext->started = TRUE;
    return status;
}

static VOID StopDevice(PDEVICE_EXTENSION ext)
{
    if (ext->classData != NULL) {
        BatteryClassUnload(ext->classData);
        ext->classData = NULL;
    }
    ext->started = FALSE;
    StopPolling();
}

NTSTATUS DispatchPnp(PDEVICE_OBJECT device, PIRP irp)
{
    PDEVICE_EXTENSION ext = device->DeviceExtension;
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(irp);
    NTSTATUS status;
    KEVENT event;

    switch (stack->MinorFunction) {
    case IRP_MN_START_DEVICE:
        KeInitializeEvent(&event, NotificationEvent, FALSE);
        IoCopyCurrentIrpStackLocationToNext(irp);
        IoSetCompletionRoutine(irp, StartCompletion, &event, TRUE, TRUE, TRUE);
        status = IoCallDriver(ext->lower, irp);
        if (status == STATUS_PENDING) {
            KeWaitForSingleObject(&event, Executive, KernelMode, FALSE, NULL);
            status = irp->IoStatus.Status;
        }
        if (NT_SUCCESS(status))
            status = StartDevice(ext);
        return CompleteIrp(irp, status);
    case IRP_MN_STOP_DEVICE:
    case IRP_MN_SURPRISE_REMOVAL:
        StopDevice(ext);
        irp->IoStatus.Status = STATUS_SUCCESS;
        break;
    case IRP_MN_REMOVE_DEVICE:
        StopDevice(ext);
        irp->IoStatus.Status = STATUS_SUCCESS;
        IoSkipCurrentIrpStackLocation(irp);
        status = IoCallDriver(ext->lower, irp);
        g_ext = NULL;
        IoDetachDevice(ext->lower);
        IoDeleteDevice(device);
        return status;
    default:
        break;
    }
    IoSkipCurrentIrpStackLocation(irp);
    return IoCallDriver(ext->lower, irp);
}

NTSTATUS DispatchPower(PDEVICE_OBJECT device, PIRP irp)
{
    PDEVICE_EXTENSION ext = device->DeviceExtension;

    PoStartNextPowerIrp(irp);
    IoSkipCurrentIrpStackLocation(irp);
    return PoCallDriver(ext->lower, irp);
}

NTSTATUS DispatchIoctl(PDEVICE_OBJECT device, PIRP irp)
{
    PDEVICE_EXTENSION ext = device->DeviceExtension;
    NTSTATUS status = STATUS_NOT_SUPPORTED;

    if (device == g_bridge)
        return BridgeDispatch(irp);
    if (ext->classData != NULL)
        status = BatteryClassIoctl(ext->classData, irp);
    if (status == STATUS_NOT_SUPPORTED) {
        IoSkipCurrentIrpStackLocation(irp);
        return IoCallDriver(ext->lower, irp);
    }
    return status;
}

NTSTATUS DispatchCreateClose(PDEVICE_OBJECT device, PIRP irp)
{
    if (device == g_bridge)
        return BridgeDispatch(irp);
    irp->IoStatus.Information = 0;
    return CompleteIrp(irp, STATUS_SUCCESS);
}

NTSTATUS DispatchPassDown(PDEVICE_OBJECT device, PIRP irp)
{
    PDEVICE_EXTENSION ext = device->DeviceExtension;

    if (device == g_bridge)
        return BridgeDispatch(irp);
    IoSkipCurrentIrpStackLocation(irp);
    return IoCallDriver(ext->lower, irp);
}

NTSTATUS AddDevice(PDRIVER_OBJECT driver, PDEVICE_OBJECT pdo)
{
    PDEVICE_OBJECT device;
    PDEVICE_EXTENSION ext;
    NTSTATUS status;

    status = IoCreateDevice(driver, sizeof(DEVICE_EXTENSION), NULL, FILE_DEVICE_BATTERY, 0, FALSE, &device);
    if (!NT_SUCCESS(status))
        return status;
    ext = device->DeviceExtension;
    RtlZeroMemory(ext, sizeof(*ext));
    ext->self = device;
    ext->pdo = pdo;
    ext->lower = IoAttachDeviceToDeviceStack(device, pdo);
    if (ext->lower == NULL) {
        IoDeleteDevice(device);
        return STATUS_NO_SUCH_DEVICE;
    }
    g_ext = ext;
    device->Flags |= DO_BUFFERED_IO | DO_POWER_PAGABLE;
    device->Flags &= ~DO_DEVICE_INITIALIZING;
    return STATUS_SUCCESS;
}

VOID Unload(PDRIVER_OBJECT driver)
{
    UNREFERENCED_PARAMETER(driver);
    StopPolling();
    BridgeStop();
}

NTSTATUS DriverEntry(PDRIVER_OBJECT driver, PUNICODE_STRING registry)
{
    UNREFERENCED_PARAMETER(registry);
    KeInitializeEvent(&g_stop, NotificationEvent, FALSE);
    ExInitializeFastMutex(&g_snapLock);

    driver->MajorFunction[IRP_MJ_PNP] = DispatchPnp;
    driver->MajorFunction[IRP_MJ_POWER] = DispatchPower;
    driver->MajorFunction[IRP_MJ_DEVICE_CONTROL] = DispatchIoctl;
    driver->MajorFunction[IRP_MJ_CREATE] = DispatchCreateClose;
    driver->MajorFunction[IRP_MJ_CLOSE] = DispatchCreateClose;
    driver->MajorFunction[IRP_MJ_CLEANUP] = DispatchCreateClose;
    driver->MajorFunction[IRP_MJ_SYSTEM_CONTROL] = DispatchPassDown;
    driver->DriverExtension->AddDevice = AddDevice;
    driver->DriverUnload = Unload;
    BridgeStart(driver);
    return STATUS_SUCCESS;
}
