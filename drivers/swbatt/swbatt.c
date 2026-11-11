// Switch battery and temperature for Windows: a battery class miniport (battc.sys)
// plus fan control.
//
// Every POLL_MS it reads over I2C1:
//   MAX17050 (0x36): fuel gauge: percent, capacity, voltage, current, battery temperature;
//   BQ24193  (0x6B): charger: whether external power is present and charging is on;
//   TMP451   (0x4C): SoC and board temperature.
// Windows sees a regular battery: tray icon with percent, "charging", remaining time,
// and shuts itself down at BATTERY_CRITICAL (the action is set by powercfg in w32.cmd).
// Fan: 50% up to FAN_LOW_C (45 C), then linear to 100% at FAN_HIGH_C (65 C); 100% if the
// temperature cannot be read. At SHUTDOWN_C and above the system is shut down.
// I2C1 is set up by UEFI (PmicDxe); no other Windows driver uses it.
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

    // PWM polarity is inverted, as in UEFI (FanStart).
    g_pwm[PWM_FAN_CSR] = PWM_ENABLE | ((FAN_DUTY_MAX - duty) << 16);
}

static ULONG FanForTemp(LONG socC)
{
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

VOID PollThread(PVOID context)
{
    LARGE_INTEGER delay;
    SNAPSHOT s, old;
    ULONG raw[8];
    ULONG tick = 0;
    ULONG tempFails = 0;
    BOOLEAN shutdownSent = FALSE;
    ULONG hot = 0;

    UNREFERENCED_PARAMETER(context);
    delay.QuadPart = -10000LL * POLL_MS;
    RtlZeroMemory(&old, sizeof(old));
    LogClocks();

    do {
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
    g_i2c = NULL;
    g_pwm = NULL;
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
    UNREFERENCED_PARAMETER(device);
    irp->IoStatus.Information = 0;
    return CompleteIrp(irp, STATUS_SUCCESS);
}

NTSTATUS DispatchPassDown(PDEVICE_OBJECT device, PIRP irp)
{
    PDEVICE_EXTENSION ext = device->DeviceExtension;

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
    driver->MajorFunction[IRP_MJ_SYSTEM_CONTROL] = DispatchPassDown;
    driver->DriverExtension->AddDevice = AddDevice;
    driver->DriverUnload = Unload;
    return STATUS_SUCCESS;
}
