// Switch touch screen for Windows: a HID minidriver exposing a touch screen digitizer
// with up to MAX_CONTACTS contacts. Windows rotates the contacts with the screen orientation itself.
// The FTS4 panel returns an event queue (READ_ALL_EVENT); each event carries the finger ID in the
// upper 4 bits of its first byte.
// Reads the panel by polling and only talks to I2C3, address 0x49.
// The volume buttons (PX6 = up, PX7 = down, low = pressed, as Switchroot's nx-keys) are read on
// the same poll and reported as a second top-level collection, Consumer Control (Volume
// Increment / Decrement), so Windows changes the volume and shows its volume flyout.
// The power button (MAX77620 ONOFFSTAT EN0 on I2C5) is polled too:
//   short press: screen off/on (the backlight on an LCD console, the panel's own brightness
//   on an OLED one, as hekate); touch is ignored while it is off;
//   held 4 s: Ctrl+Alt+Del from a minimal keyboard collection, so Windows shows its security
//   screen with the power menu (shut down, restart) and a Cancel button;
//   held with volume up/down: backlight brighter/darker, no volume change.
// Clock: the MAX77620 RTC (I2C5, 0x68) keeps running while the console is off. Once Windows
// has a real time (after NTP), the offset between it and the RTC is kept in
// Services\swhid\Parameters\RtcOffset; at every start the system time is set to RTC + offset.
// The RTC itself is never written (Horizon uses it).
#define TOUCHREAD_CORE_ONLY
#include "../touchread/touchread.c"
#include <hidport.h>

#define VENDOR_ID       0x057E
#define PRODUCT_ID      0x2003
#define VERSION_NUMBER  0x0004
#define REPORT_ID_TOUCH 1
#define REPORT_ID_MAX   2
#define REPORT_ID_KEYS  3
#define REPORT_ID_SAS   5
#define SAS_REPORT_SIZE 3
#define I2C5_BASE       0x7000D000ULL
#define I2C5_SIZE       0x100
#define PMIC_ADDR       0x3C
#define PMIC_ONOFFSTAT  0x15
#define PMIC_EN0        (1u << 2)       // power button pressed
#define RTC_ADDR        0x68
#define PWM_BASE        0x7000A000ULL
#define PWM_SIZE        0x100
#define PWM_CSR0        0                // backlight
#define PWM_ENABLE      0x80000000u
#define PINMUX_BASE     0x70003000ULL
#define PINMUX_SIZE     0x1000
#define PINMUX_LCD_BL_PWM (0x1FC / 4)
#define GPIO_PV_CNF     (0x504 / 4)     // bank 5, port V: PV0 = LCD_BL_PWM, PV1 = LCD_BL_EN
#define GPIO_PV_OE      (0x514 / 4)
#define GPIO_PV_OUT     (0x524 / 4)
#define SAS_HOLD_POLLS  10               // Ctrl+Alt+Del held for 100 ms before the release
#define CAR_BASE        0x60006000ULL
#define CAR_CLK_OUT_ENB_L (0x010 / 4)
#define CLK_L_PWM       (1u << 17)
#define CAR_RST_DEV_L   (0x004 / 4)
#define DC_BASE         0x54200000ULL    // display controller A
#define DC_SIZE         0x1000
#define DC_CMD_INT_STATUS 0x37           // word indexes, as in hekate's di.h
#define DC_CMD_INT_ENABLE 0x39
#define DC_INT_FRAME_END (1u << 1)
#define DC_BACKLIGHT_LEVEL 0x326         // scratch register B: hekate keeps its OLED duty here
#define DSI_BASE        0x54300000ULL
#define DSI_SIZE        0x400
#define DSI_INCR_SYNCPT_CNTRL 0x1
#define DSI_INCR_SYNCPT_SOFT_RESET 1u
#define DSI_WR_DATA     0xA
#define DSI_VIDEO_MODE_CONTROL 0x4E
#define DSI_CMD_PKT_VID_ENABLE 1u
#define DSI_LINE_TYPE_4 (4u << 1)
#define MIPI_DSI_DCS_LONG_WRITE 0x39u
#define MIPI_DCS_SET_BRIGHTNESS 0x51u
#define OLED_LEVEL_MAX  2047             // PANEL_SM_BL_CANDELA_MAX
#define POWER_EVERY     5                // read the power button every 5 polls (50 ms)
#define POWER_HOLD_MS   4000
#define BRIGHT_STEP     16
#define BRIGHT_MIN      8
#define CLOCK_EVERY     6000             // learn the RTC offset every 60 s
#define UNIX_1601       116444736000000000LL
#define PLAUSIBLE_UNIX  1735689600LL     // 2025-01-01: Windows' time is real, not UEFI's 2022
#define KEY_REPORT_SIZE 2
#define KEY_QUEUE       8
#define GPIO_BASE       0x6000D000ULL
#define GPIO_SIZE       0x1000
#define GPIO_PX_CNF     (0x50C / 4)     // bank 5, port X
#define GPIO_PX_OE      (0x51C / 4)
#define GPIO_PX_IN      (0x53C / 4)
#define PX_VOL_UP       (1u << 6)
#define PX_VOL_DOWN     (1u << 7)
#define KEY_REPEAT_MS   500             // held longer: one more step every KEY_STEP_MS
#define KEY_STEP_MS     150
#define FINGER_SIZE     6
#define MAX_CONTACTS    5
#define REPORT_SIZE     (2 + FINGER_SIZE * MAX_CONTACTS)
#define CMD_READ_ALL    0x86
#define STACK_EVENTS    8
#define PANEL_SLOTS     10
#define AXIS_MAX        32767
#define RAW_LONG_MAX    1280
#define RAW_SHORT_MAX   720
#define POLL_MS         10
#define PANEL_RETRY_POLLS 500           // panel not answering: init again every ~5 s
#define PANEL_LOST_READS  50            // that many failed reads in a row: panel lost
#define TIP_CONFIDENCE  3           // Tip Switch and Confidence

// Windows 8+ touch screen: MAX_CONTACTS fingers (Tip, Confidence, Contact ID, X, Y),
// contact count in the input report and Contact Count Maximum in the feature report.
// Physical size of the Switch screen: 77 x 137 mm (units of 0.1 mm).
#define FINGER_COLLECTION \
    0x05, 0x0D, 0x09, 0x22, 0xA1, 0x02, \
    0x09, 0x42, 0x09, 0x47, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x02, 0x81, 0x02, \
    0x95, 0x06, 0x81, 0x03, \
    0x09, 0x51, 0x25, 0x0F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02, \
    0x05, 0x01, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x01, \
    0x55, 0x0E, 0x65, 0x11, 0x35, 0x00, \
    0x46, 0x02, 0x03, 0x09, 0x30, 0x81, 0x02, \
    0x46, 0x5A, 0x05, 0x09, 0x31, 0x81, 0x02, \
    0x55, 0x00, 0x65, 0x00, 0x45, 0x00, \
    0xC0

static const UCHAR g_reportDescriptor[] = {
    0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01,
    0x85, REPORT_ID_TOUCH,
    FINGER_COLLECTION, FINGER_COLLECTION, FINGER_COLLECTION, FINGER_COLLECTION, FINGER_COLLECTION,
    0x05, 0x0D, 0x09, 0x54, 0x25, 0x0A, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
    0x85, REPORT_ID_MAX, 0x09, 0x55, 0x25, 0x0A, 0x75, 0x08, 0x95, 0x01, 0xB1, 0x02,
    0xC0,
    // Consumer Control: bit 0 Volume Increment, bit 1 Volume Decrement.
    0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01,
    0x85, REPORT_ID_KEYS, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x02,
    0x09, 0xE9, 0x09, 0xEA, 0x81, 0x02,
    0x95, 0x06, 0x81, 0x03,
    0xC0,
    // Keyboard, only for Ctrl+Alt+Del: modifier bits and one key.
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
    0x85, REPORT_ID_SAS, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x75, 0x08, 0x95, 0x01, 0x15, 0x00, 0x25, 0x65, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xC0
};

NTSYSAPI NTSTATUS NTAPI ZwSetSystemTime(PLARGE_INTEGER SystemTime, PLARGE_INTEGER PreviousTime);

static HID_DESCRIPTOR g_hidDescriptor = {
    sizeof(HID_DESCRIPTOR), HID_HID_DESCRIPTOR_TYPE, 0x0111, 0, 1,
    { HID_REPORT_DESCRIPTOR_TYPE, sizeof(g_reportDescriptor) }
};

static KSPIN_LOCK g_lock;
static LIST_ENTRY g_reads;
static KEVENT g_stop;
static PVOID g_thread;
static UCHAR g_report[REPORT_SIZE];
static LONG g_dirty;
static volatile ULONG *g_gpio;
static ULONG g_stats[5];                 // panel reads ok, read failures, events, touch reports, key reports
static UCHAR g_keyQueue[KEY_QUEUE];      // pending key states, sent before touch reports
static UCHAR g_keyIds[KEY_QUEUE];
static volatile ULONG *g_i2c5;
static volatile ULONG *g_pwm;
static BOOLEAN g_screenOff;
static ULONG g_duty;                     // backlight duty 0..255 while the screen is on
static volatile ULONG *g_pinmux;
static BOOLEAN g_pwmMode;                // LCD_BL_PWM driven by PWM channel 0 (not a GPIO)
static BOOLEAN g_oled;                   // OLED panel: brightness over DSI, no backlight pins
static volatile ULONG *g_dc, *g_dsi;
static ULONG g_sasRelease;               // polls left until the Ctrl+Alt+Del release report
static ULONG g_keyHead, g_keyCount;      // used by the poll thread only

static PDEVICE_OBJECT NextDevice(PDEVICE_OBJECT device)
{
    return ((PHID_DEVICE_EXTENSION) device->DeviceExtension)->NextDeviceObject;
}

VOID CancelRead(PDEVICE_OBJECT device, PIRP irp)
{
    KIRQL irql;

    UNREFERENCED_PARAMETER(device);
    IoReleaseCancelSpinLock(irp->CancelIrql);
    KeAcquireSpinLock(&g_lock, &irql);
    RemoveEntryList(&irp->Tail.Overlay.ListEntry);
    KeReleaseSpinLock(&g_lock, irql);
    irp->IoStatus.Status = STATUS_CANCELLED;
    irp->IoStatus.Information = 0;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
}

static PIRP PopRead(VOID)
{
    PIRP irp = NULL;
    KIRQL irql;

    KeAcquireSpinLock(&g_lock, &irql);
    while (!IsListEmpty(&g_reads)) {
        PLIST_ENTRY entry = RemoveHeadList(&g_reads);
        PIRP candidate = CONTAINING_RECORD(entry, IRP, Tail.Overlay.ListEntry);

        if (IoSetCancelRoutine(candidate, NULL) != NULL) {
            irp = candidate;
            break;
        }
        InitializeListHead(entry);  // cancellation is in progress, CancelRead will complete it
    }
    KeReleaseSpinLock(&g_lock, irql);
    return irp;
}

static VOID QueueReport(UCHAR id, UCHAR state)
{
    if (g_keyCount < KEY_QUEUE) {
        g_keyIds[(g_keyHead + g_keyCount) % KEY_QUEUE] = id;
        g_keyQueue[(g_keyHead + g_keyCount) % KEY_QUEUE] = state;
        g_keyCount++;
    }
}

static VOID QueueKeys(UCHAR state)
{
    QueueReport(REPORT_ID_KEYS, state);
}

// Key reports first (they are rare and must not be lost), then the touch report.
static VOID FlushReports(VOID)
{
    PIRP irp;

    while (g_keyCount != 0) {
        UCHAR *buffer;

        irp = PopRead();
        if (irp == NULL)
            return;
        buffer = (UCHAR *) irp->UserBuffer;
        buffer[0] = g_keyIds[g_keyHead];
        buffer[1] = g_keyQueue[g_keyHead];
        if (buffer[0] == REPORT_ID_SAS) {
            // State 1: Left Ctrl + Left Alt, Delete (0x4C); state 0: released.
            buffer[1] = g_keyQueue[g_keyHead] ? 0x05 : 0;
            buffer[2] = g_keyQueue[g_keyHead] ? 0x4C : 0;
        }
        g_keyHead = (g_keyHead + 1) % KEY_QUEUE;
        g_keyCount--;
        g_stats[4]++;
        irp->IoStatus.Status = STATUS_SUCCESS;
        irp->IoStatus.Information = buffer[0] == REPORT_ID_SAS ? SAS_REPORT_SIZE : KEY_REPORT_SIZE;
        IoCompleteRequest(irp, IO_NO_INCREMENT);
    }
    if (InterlockedExchange(&g_dirty, 0) == 0)
        return;
    irp = PopRead();
    if (irp == NULL) {
        InterlockedExchange(&g_dirty, 1);
        return;
    }
    RtlCopyMemory(irp->UserBuffer, g_report, REPORT_SIZE);
    g_stats[3]++;
    irp->IoStatus.Status = STATUS_SUCCESS;
    irp->IoStatus.Information = REPORT_SIZE;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
}

// ---- I2C5 (PMIC, RTC), normal mode, up to 4 bytes; only this driver uses it in Windows ----

// I2C5 is shared with swbatt (the GPU power bridge): one user at a time through a named
// synchronization event. A wait that times out proceeds, so the buttons never stall for good.
static PKEVENT g_i2c5Lock;
static HANDLE g_i2c5LockHandle;

static VOID I2c5LockOpen(VOID)
{
    UNICODE_STRING name;

    RtlInitUnicodeString(&name, L"\\BaseNamedObjects\\SwitchWoaI2c5");
    g_i2c5Lock = IoCreateSynchronizationEvent(&name, &g_i2c5LockHandle);
}

static VOID I2c5LockClose(VOID)
{
    if (g_i2c5LockHandle != NULL)
        ZwClose(g_i2c5LockHandle);
    g_i2c5LockHandle = NULL;
    g_i2c5Lock = NULL;
}

static BOOLEAN P5XferRaw(UCHAR addr, BOOLEAN read, ULONG *data, ULONG size);

static BOOLEAN P5Xfer(UCHAR addr, BOOLEAN read, ULONG *data, ULONG size)
{
    LARGE_INTEGER timeout;
    BOOLEAN ok;

    timeout.QuadPart = -10000LL * 200;
    if (g_i2c5Lock != NULL)
        (VOID) KeWaitForSingleObject(g_i2c5Lock, Executive, KernelMode, FALSE, &timeout);
    ok = P5XferRaw(addr, read, data, size);
    if (g_i2c5Lock != NULL)
        KeSetEvent(g_i2c5Lock, IO_NO_INCREMENT, FALSE);
    return ok;
}

static BOOLEAN P5XferRaw(UCHAR addr, BOOLEAN read, ULONG *data, ULONG size)
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

static BOOLEAN P5Read(UCHAR addr, UCHAR reg, UCHAR *value)
{
    ULONG data = reg;

    if (!P5Xfer(addr, FALSE, &data, 1) || !P5Xfer(addr, TRUE, &data, 1))
        return FALSE;
    *value = (UCHAR) data;
    return TRUE;
}

static BOOLEAN P5Write(UCHAR addr, UCHAR reg, UCHAR value)
{
    ULONG data = reg | ((ULONG) value << 8);

    return P5Xfer(addr, FALSE, &data, 2);
}

// A touch panel that stopped answering keeps that state across reboots (its 2.9 V supply, PMIC
// LDO6, stays on). Power it off and on as hekate's touch_power_off()/touch_power_on() do: reset
// (PJ7) low, LDO6 off for 700 ms, LDO6 on, reset high after 5 ms, then 50 ms for the panel.
#define PMIC_LDO6_CFG    0x2F
#define LDO_MODE_MASK    0xC0           // power mode, 3 = normal, 0 = off
#define LDO_VOLT_MASK    0x3F
#define LDO6_2V9         0x2A           // (2.9 V - 0.8 V) / 50 mV: "vdd-tp-2v9" in Switchroot
#define GPIO_PJ_CNF      (0x204 / 4)
#define GPIO_PJ_OE       (0x214 / 4)
#define GPIO_PJ_OUT      (0x224 / 4)
#define PJ7              (1u << 7)      // touch reset, low = in reset

static VOID TouchPowerCycle(VOID)
{
    UCHAR cfg;
    BOOLEAN pin = g_gpio != NULL && (g_gpio[GPIO_PJ_CNF] & PJ7) && (g_gpio[GPIO_PJ_OE] & PJ7);

    if (g_i2c5 == NULL || !P5Read(PMIC_ADDR, PMIC_LDO6_CFG, &cfg)) {
        LogText("touch: no PMIC access, no power cycle\r\n");
        return;
    }
    if (pin)
        g_gpio[GPIO_PJ_OUT] &= ~PJ7;
    // Off, and at 2.9 V when it comes back: it was found at 1.0 V (0x04), where the panel answers
    // on I2C but senses nothing.
    P5Write(PMIC_ADDR, PMIC_LDO6_CFG, LDO6_2V9);
    // Long enough for the rail to discharge: a short dip leaves the panel half-reset.
    SleepMs(700);
    P5Write(PMIC_ADDR, PMIC_LDO6_CFG, LDO_MODE_MASK | LDO6_2V9);
    SleepMs(5);
    if (pin)
        g_gpio[GPIO_PJ_OUT] |= PJ7;
    SleepMs(50);
    LogText(pin ? "touch: power cycled, LDO6 " : "touch: power cycled (no reset pin), LDO6 ");
    LogHex(cfg, 2);
    if (P5Read(PMIC_ADDR, PMIC_LDO6_CFG, &cfg))
        LogHex(cfg, 2);
    if (P5Read(PMIC_ADDR, PMIC_LDO6_CFG + 1, &cfg))
        LogHex(cfg, 2);
    LogText("\r\n");
}

// ---- Clock -------------------------------------------------------------------------

static LONGLONG DaysFromCivil(LONG y, ULONG m, ULONG d)
{
    LONG era;
    ULONG yoe, doy, doe;

    y -= m <= 2;
    era = (y >= 0 ? y : y - 399) / 400;
    yoe = (ULONG) (y - era * 400);
    doy = (153 * (m + (m > 2 ? (ULONG) -3 : 9)) + 2) / 5 + d - 1;
    doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return (LONGLONG) era * 146097 + (LONGLONG) doe - 719468;
}

static ULONG FromBcd(UCHAR v, BOOLEAN bcd)
{
    return bcd ? (ULONG) ((v >> 4) * 10 + (v & 0xF)) : v;
}

// RTC as seconds since 1970 (its own reference; the stored offset makes it real time).
static BOOLEAN RtcRead(LONGLONG *seconds)
{
    UCHAR control, r[7];
    ULONG sec, min, hour, day, month, year;
    BOOLEAN bcd;

    if (g_i2c5 == NULL || !P5Write(RTC_ADDR, 0x04, 0x10))       // UPDATE0: registers from the clock
        return FALSE;
    KeStallExecutionProcessor(1000);
    if (!P5Read(RTC_ADDR, 0x03, &control))
        return FALSE;
    for (ULONG i = 0; i < 7; i++) {
        if (!P5Read(RTC_ADDR, (UCHAR) (0x07 + i), &r[i]))
            return FALSE;
    }
    bcd = (control & 1) == 0;
    sec = FromBcd(r[0] & 0x7F, bcd);
    min = FromBcd(r[1] & 0x7F, bcd);
    if (control & 2) {
        hour = FromBcd(r[2] & 0x3F, bcd);
    } else {
        hour = FromBcd(r[2] & 0x1F, bcd) % 12;
        if (r[2] & 0x40)
            hour += 12;
    }
    month = FromBcd(r[4] & 0x1F, bcd);
    year = FromBcd(r[5] & 0x7F, bcd) + 2000;
    day = FromBcd(r[6] & 0x3F, bcd);
    if (sec > 59 || min > 59 || hour > 23 || month < 1 || month > 12 || day < 1 || day > 31)
        return FALSE;
    *seconds = ((DaysFromCivil((LONG) year, month, day) * 24 + hour) * 60 + min) * 60 + sec;
    return TRUE;
}

static LONGLONG UnixNow(VOID)
{
    LARGE_INTEGER now;

    KeQuerySystemTime(&now);
    return (now.QuadPart - UNIX_1601) / 10000000;
}

static HANDLE OpenParameters(VOID)
{
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES attributes;
    HANDLE key = NULL;

    RtlInitUnicodeString(&name, L"\\Registry\\Machine\\System\\CurrentControlSet\\Services\\swhid\\Parameters");
    InitializeObjectAttributes(&attributes, &name, OBJ_KERNEL_HANDLE | OBJ_CASE_INSENSITIVE, NULL, NULL);
    if (!NT_SUCCESS(ZwCreateKey(&key, KEY_READ | KEY_WRITE, &attributes, 0, NULL, REG_OPTION_NON_VOLATILE, NULL)))
        return NULL;
    return key;
}

static BOOLEAN OffsetLoad(LONGLONG *offset)
{
    UNICODE_STRING name;
    UCHAR buffer[sizeof(KEY_VALUE_PARTIAL_INFORMATION) + sizeof(LONGLONG)];
    PKEY_VALUE_PARTIAL_INFORMATION info = (PKEY_VALUE_PARTIAL_INFORMATION) buffer;
    ULONG length;
    HANDLE key = OpenParameters();
    BOOLEAN ok;

    if (key == NULL)
        return FALSE;
    RtlInitUnicodeString(&name, L"RtcOffset");
    ok = NT_SUCCESS(ZwQueryValueKey(key, &name, KeyValuePartialInformation, info, sizeof(buffer), &length)) &&
         info->Type == REG_QWORD && info->DataLength == sizeof(LONGLONG);
    if (ok)
        RtlCopyMemory(offset, info->Data, sizeof(LONGLONG));
    ZwClose(key);
    return ok;
}

static VOID OffsetSave(LONGLONG offset)
{
    UNICODE_STRING name;
    HANDLE key = OpenParameters();

    if (key == NULL)
        return;
    RtlInitUnicodeString(&name, L"RtcOffset");
    ZwSetValueKey(key, &name, 0, REG_QWORD, &offset, sizeof(offset));
    ZwFlushKey(key);
    ZwClose(key);
}

static LONGLONG g_offset;
static BOOLEAN g_offsetKnown;

// At start: system time = RTC + stored offset, when they differ by more than 30 s.
static VOID ClockStart(VOID)
{
    LONGLONG rtc, target, now;
    LARGE_INTEGER time;

    g_offsetKnown = OffsetLoad(&g_offset);
    if (!RtcRead(&rtc)) {
        LogText("clock: rtc read failed\r\n");
        return;
    }
    if (!g_offsetKnown) {
        LogText("clock: no offset yet\r\n");
        return;
    }
    target = rtc + g_offset;
    now = UnixNow();
    if (target < PLAUSIBLE_UNIX || (target - now < 30 && now - target < 30))
        return;
    time.QuadPart = target * 10000000 + UNIX_1601;
    LogText(NT_SUCCESS(ZwSetSystemTime(&time, NULL)) ? "clock: set from rtc\r\n" : "clock: set failed\r\n");
}

// While Windows has a real time, keep the offset to the RTC (it follows NTP and manual changes).
static VOID ClockLearn(VOID)
{
    LONGLONG rtc, now = UnixNow(), offset;

    if (now < PLAUSIBLE_UNIX || !RtcRead(&rtc))
        return;
    offset = now - rtc;
    if (g_offsetKnown && offset - g_offset < 3 && g_offset - offset < 3)
        return;
    g_offset = offset;
    g_offsetKnown = TRUE;
    OffsetSave(offset);
    LogText("clock: offset saved\r\n");
    SaveLog();
}

// ---- Backlight ---------------------------------------------------------------------

// Two kinds of console, told apart by what hekate left behind:
//   LCD: a WLED driver, enable on PV1 (GPIO output, high) and brightness on LCD_BL_PWM (PV0),
//        either a GPIO driven high or PWM channel 0;
//   OLED (HEG-001): hekate configures neither pin; the panel sets its own brightness from the
//        DCS command SET_BRIGHTNESS, sent over DSI during vertical blanking.
// Both follow hekate's bdk/display/di.c.

// One DC frame-end interrupt (polled: the interrupt itself stays masked), at most 100 ms.
static BOOLEAN DcWaitFrameEnd(VOID)
{
    g_dc[DC_CMD_INT_STATUS] = DC_INT_FRAME_END;
    for (ULONG i = 0; i < 2000; i++) {
        if (g_dc[DC_CMD_INT_STATUS] & DC_INT_FRAME_END)
            return TRUE;
        KeStallExecutionProcessor(50);
    }
    return FALSE;
}

// display_dsi_vblank_write(MIPI_DCS_SET_BRIGHTNESS, 2 bytes): the long packet goes out on
// the 4th line of the next frame, between two frame ends; the video stream is not stopped.
static BOOLEAN OledBrightness(ULONG duty)
{
    ULONG level = duty * OLED_LEVEL_MAX / 255;
    BOOLEAN ok;

    if (g_dc == NULL || g_dsi == NULL)
        return FALSE;
    g_dc[DC_CMD_INT_ENABLE] |= DC_INT_FRAME_END;
    g_dsi[DSI_VIDEO_MODE_CONTROL] = DSI_CMD_PKT_VID_ENABLE | DSI_LINE_TYPE_4;
    ok = DcWaitFrameEnd();
    if (ok) {
        g_dsi[DSI_WR_DATA] = (3u << 8) | MIPI_DSI_DCS_LONG_WRITE;      // command + 2 bytes
        g_dsi[DSI_WR_DATA] = MIPI_DCS_SET_BRIGHTNESS | ((level >> 8) << 8) | ((level & 0xFF) << 16);
        ok = DcWaitFrameEnd();
        KeStallExecutionProcessor(14);
        g_dsi[DSI_INCR_SYNCPT_CNTRL] = DSI_INCR_SYNCPT_SOFT_RESET;
        KeStallExecutionProcessor(300);
        g_dsi[DSI_INCR_SYNCPT_CNTRL] = 0;
        KeStallExecutionProcessor(300);
    }
    g_dsi[DSI_VIDEO_MODE_CONTROL] = 0;
    g_dc[DC_CMD_INT_ENABLE] &= ~DC_INT_FRAME_END;
    g_dc[DC_CMD_INT_STATUS] = DC_INT_FRAME_END;
    if (!ok)
        LogText("backlight: no frame end from the display controller\r\n");
    return ok;
}

// LCD: display_backlight_pwm_init(), once, the first time the brightness changes. The duty
// goes in first, and only a PWM that keeps it gets the pin.
static BOOLEAN LcdPwm(VOID)
{
    PHYSICAL_ADDRESS address;
    volatile ULONG *car;
    BOOLEAN clock;
    ULONG csr = PWM_ENABLE | ((g_screenOff ? 0 : g_duty) << 16);

    if (g_pwmMode)
        return TRUE;
    if (g_pwm == NULL || g_pinmux == NULL)
        return FALSE;
    address.QuadPart = CAR_BASE;
    car = MmMapIoSpace(address, 0x100, MmNonCached);
    if (car == NULL)
        return FALSE;
    clock = (car[CAR_CLK_OUT_ENB_L] & CLK_L_PWM) != 0 && !(car[CAR_RST_DEV_L] & CLK_L_PWM);
    MmUnmapIoSpace((PVOID) car, 0x100);
    if (clock) {
        g_pwm[PWM_CSR0] = csr;
        clock = g_pwm[PWM_CSR0] == csr;
    }
    if (!clock) {
        LogText("backlight: PWM not running, left alone\r\n");
        return FALSE;
    }
    g_pinmux[PINMUX_LCD_BL_PWM] = (g_pinmux[PINMUX_LCD_BL_PWM] & ~3u) | 1;
    g_gpio[GPIO_PV_CNF] &= ~1u;
    g_pwmMode = TRUE;
    LogText("backlight: PWM mode\r\n");
    return TRUE;
}

// Brightness 0..255 (0: off). FALSE: nothing changed.
static BOOLEAN BacklightSet(ULONG duty)
{
    if (g_oled)
        return OledBrightness(duty);
    if (!g_pwmMode && (duty == 0 || duty == 255) && (g_gpio[GPIO_PV_CNF] & 1u) && (g_gpio[GPIO_PV_OE] & 1u)) {
        // display_backlight(): the pin is still a GPIO, low = off, high = full brightness.
        g_gpio[GPIO_PV_OUT] = duty ? (g_gpio[GPIO_PV_OUT] | 1u) : (g_gpio[GPIO_PV_OUT] & ~1u);
        return TRUE;
    }
    if (!LcdPwm())
        return FALSE;
    g_pwm[PWM_CSR0] = PWM_ENABLE | (duty << 16);
    return TRUE;
}

// Screen off/on. Touch is dropped only while the screen is really off.
static VOID ScreenOn(BOOLEAN on)
{
    BOOLEAN ok = BacklightSet(on ? g_duty : 0);

    LogText(!ok ? "backlight: cannot switch\r\n" : on ? "backlight: on\r\n" : "backlight: off\r\n");
    SaveLog();
    if (ok)
        g_screenOff = !on;
}

static VOID Brightness(LONG step)
{
    LONG duty = (LONG) g_duty + step;
    ULONG old = g_duty;

    g_duty = (ULONG) (duty < BRIGHT_MIN ? BRIGHT_MIN : duty > 255 ? 255 : duty);
    if (BacklightSet(g_duty)) {
        g_screenOff = FALSE;
    } else {
        g_duty = old;
        LogText("backlight: cannot change\r\n");
    }
    LogText(step > 0 ? "backlight: up, duty " : "backlight: down, duty ");
    LogHex(g_duty, 2);
    LogText("\r\n");
    SaveLog();
}

// ---- Buttons -----------------------------------------------------------------------

// Volume: two equal samples (20 ms) make a change; held, one more release/press pair every
// KEY_STEP_MS after KEY_REPEAT_MS. Power (read every 50 ms): see the top of the file.
static VOID PollKeys(ULONG polls)
{
    static UCHAR last, stable, sent;
    static ULONG heldMs, powerMs;
    static ULONGLONG powerStart;
    static BOOLEAN power, combo, powerSent;
    ULONG in;
    UCHAR now;

    if (g_gpio == NULL)
        return;
    if (g_sasRelease != 0 && --g_sasRelease == 0)
        QueueReport(REPORT_ID_SAS, 0);
    if (g_i2c5 != NULL && polls % POWER_EVERY == 0) {
        UCHAR status;

        if (P5Read(PMIC_ADDR, PMIC_ONOFFSTAT, &status))
            power = (status & PMIC_EN0) != 0;
    }
    if (power) {
        // Real time: a 10 ms wait lasts a whole timer tick (15.6 ms or more) in Windows.
        if (powerMs == 0) {
            powerStart = KeQueryInterruptTime();
            LogText("power: down\r\n");
            SaveLog();
        }
        powerMs = (ULONG) ((KeQueryInterruptTime() - powerStart) / 10000) + 1;
        if (!combo && !powerSent && powerMs >= POWER_HOLD_MS) {
            QueueReport(REPORT_ID_SAS, 1);
            g_sasRelease = SAS_HOLD_POLLS;
            LogText("power: ctrl+alt+del\r\n");
            SaveLog();
            powerSent = TRUE;
        }
    } else if (powerMs != 0) {
        LogText("power: up after ");
        LogHex(powerMs, 5);
        LogText(combo ? " ms, brightness\r\n" : powerSent ? " ms, ctrl+alt+del\r\n" : " ms, screen\r\n");
        SaveLog();
        if (!combo && !powerSent)
            ScreenOn(g_screenOff);
        powerMs = 0;
        combo = FALSE;
        powerSent = FALSE;
    }

    in = g_gpio[GPIO_PX_IN];
    now = (UCHAR) (((in & PX_VOL_UP) ? 0 : 1) | ((in & PX_VOL_DOWN) ? 0 : 2));
    if (now != last) {
        last = now;
        return;
    }
    if (now != stable) {
        stable = now;
        heldMs = 0;
        if (power) {
            // Power held: volume buttons change the brightness instead of the volume.
            combo = TRUE;
            if (now == 1)
                Brightness(BRIGHT_STEP);
            else if (now == 2)
                Brightness(-BRIGHT_STEP);
            return;
        }
        if (now != sent) {
            QueueKeys(now);
            sent = now;
        }
        return;
    }
    if (stable == 0 || power)
        return;
    heldMs += POLL_MS;
    if (heldMs >= KEY_REPEAT_MS && (heldMs - KEY_REPEAT_MS) % KEY_STEP_MS == 0) {
        QueueKeys(0);
        QueueKeys(stable);
    }
}

// The pins stay as firmware left them, only as inputs: hekate reads the same buttons.
static VOID StartKeys(VOID)
{
    PHYSICAL_ADDRESS address;
    ULONG pins = PX_VOL_UP | PX_VOL_DOWN;

    address.QuadPart = GPIO_BASE;
    g_gpio = MmMapIoSpace(address, GPIO_SIZE, MmNonCached);
    if (g_gpio == NULL)
        return;
    if ((g_gpio[GPIO_PX_CNF] & pins) != pins || (g_gpio[GPIO_PX_OE] & pins) != 0) {
        LogText("hid: volume pins are not GPIO inputs, buttons off\r\n");
        MmUnmapIoSpace((PVOID) g_gpio, GPIO_SIZE);
        g_gpio = NULL;
        return;
    }
    LogText("hid: volume buttons ok\r\n");
    address.QuadPart = I2C5_BASE;
    g_i2c5 = MmMapIoSpace(address, I2C5_SIZE, MmNonCached);
    I2c5LockOpen();
    address.QuadPart = PWM_BASE;
    g_pwm = MmMapIoSpace(address, PWM_SIZE, MmNonCached);
    address.QuadPart = PINMUX_BASE;
    g_pinmux = MmMapIoSpace(address, PINMUX_SIZE, MmNonCached);
    address.QuadPart = DC_BASE;
    g_dc = MmMapIoSpace(address, DC_SIZE, MmNonCached);
    address.QuadPart = DSI_BASE;
    g_dsi = MmMapIoSpace(address, DSI_SIZE, MmNonCached);
    if (g_pwm != NULL && g_pinmux != NULL && g_dc != NULL && g_dsi != NULL) {
        // No WLED enable output on PV1: an OLED console, hekate's duty is in the DC scratch
        // register. LCD: PWM already (hekate's menu ran) keeps its duty, a GPIO is full brightness.
        g_oled = !(g_gpio[GPIO_PV_CNF] & 2u) || !(g_gpio[GPIO_PV_OE] & 2u);
        g_pwmMode = !g_oled && (g_pinmux[PINMUX_LCD_BL_PWM] & 3u) == 1 && !(g_gpio[GPIO_PV_CNF] & 1u);
        g_duty = g_oled ? g_dc[DC_BACKLIGHT_LEVEL] : g_pwmMode ? (g_pwm[PWM_CSR0] >> 16) & 0xFF : 255;
        LogText(g_oled ? "backlight: oled, duty " : g_pwmMode ? "backlight: lcd pwm, duty " : "backlight: lcd gpio, duty ");
        LogHex(g_duty, 8);
        LogText("\r\n");
        if (g_duty < BRIGHT_MIN || g_duty > 255)
            g_duty = 150;
    } else {
        LogText("backlight: mapping failed\r\n");
        g_oled = FALSE;
        g_pwmMode = FALSE;
    }
    ClockStart();
}

typedef struct _CONTACT {
    UCHAR state;            // 0: none, 1: finger down, 2: just released
    ULONG x;
    ULONG y;
} CONTACT;

static CONTACT g_contacts[PANEL_SLOTS];

static VOID UpdateContact(const UCHAR *event)
{
    ULONG id = event[0] & EV_ID_MASK;
    ULONG slot = event[0] >> 4;
    ULONG rawLong, rawShort;

    if (slot >= PANEL_SLOTS || (id != EV_ENTER && id != EV_MOTION && id != EV_LEAVE))
        return;
    rawLong = ((ULONG) event[1] << 4) | (event[3] >> 4);
    rawShort = ((ULONG) event[2] << 4) | (event[3] & 0xF);
    if (rawShort >= RAW_SHORT_MAX)
        rawShort = RAW_SHORT_MAX - 1;
    if (rawLong >= RAW_LONG_MAX)
        rawLong = RAW_LONG_MAX - 1;
    if (id == EV_LEAVE) {
        if (g_contacts[slot].state == 1)
            g_contacts[slot].state = 2;
        return;
    }
    g_contacts[slot].state = 1;
    g_contacts[slot].x = rawShort * AXIS_MAX / (RAW_SHORT_MAX - 1);
    g_contacts[slot].y = (RAW_LONG_MAX - 1 - rawLong) * AXIS_MAX / (RAW_LONG_MAX - 1);
}

// Builds a report from all fingers on the screen and the ones just released (sent once with Tip = 0).
// While at least one finger is down, the report is repeated on every poll (~100 Hz).
static VOID BuildReport(VOID)
{
    ULONG count = 0;

    if (g_screenOff) {
        // Backlight off: the screen cannot be seen, so touches are dropped.
        RtlZeroMemory(g_contacts, sizeof(g_contacts));
        return;
    }

    RtlZeroMemory(g_report, REPORT_SIZE);
    g_report[0] = REPORT_ID_TOUCH;
    for (ULONG slot = 0; slot < PANEL_SLOTS && count < MAX_CONTACTS; slot++) {
        CONTACT *c = &g_contacts[slot];
        UCHAR *f = &g_report[1 + count * FINGER_SIZE];

        if (c->state == 0)
            continue;
        f[0] = c->state == 1 ? TIP_CONFIDENCE : 2;
        f[1] = (UCHAR) slot;
        f[2] = (UCHAR) c->x;
        f[3] = (UCHAR) (c->x >> 8);
        f[4] = (UCHAR) c->y;
        f[5] = (UCHAR) (c->y >> 8);
        if (c->state == 2)
            c->state = 0;
        count++;
    }
    g_report[REPORT_SIZE - 1] = (UCHAR) count;
    if (count != 0)
        InterlockedExchange(&g_dirty, 1);
}

VOID PollThread(PVOID context)
{
    LARGE_INTEGER delay;
    UCHAR events[EVENT_SIZE * STACK_EVENTS];

    UNREFERENCED_PARAMETER(context);
    delay.QuadPart = -10000LL * POLL_MS;
    UCHAR ldo6 = 0;
    StartKeys();
    // The touch supply must be 2.9 V before the panel is started.
    if (g_i2c5 != NULL && P5Read(PMIC_ADDR, PMIC_LDO6_CFG, &ldo6) &&
            ldo6 != (LDO_MODE_MASK | LDO6_2V9)) {
        LogText("touch: LDO6 was ");
        LogHex(ldo6, 2);
        LogText("\r\n");
        TouchPowerCycle();
    }
    BOOLEAN panel = InitPanel();
    ULONG failures = 0, tries = 1;
    LogText(panel ? "hid: panel ok\r\n" : "hid: panel FAILED\r\n");
    SaveLog();

    ULONG polls = 0;

    while (KeWaitForSingleObject(&g_stop, Executive, KernelMode, FALSE, &delay) == STATUS_TIMEOUT) {
        // A panel that does not answer makes every read wait for the I2C timeout, which
        // would slow the buttons down too: then it is only tried again every 5 s.
        if (!panel) {
            // Ten quick tries (5 s apart), then one a minute: each costs the buttons about a second.
            if (polls % (tries < 10 ? PANEL_RETRY_POLLS : 12 * PANEL_RETRY_POLLS) == PANEL_RETRY_POLLS - 1) {
                tries++;
                TouchPowerCycle();
                panel = InitPanel();
                LogText(panel ? "hid: panel ok\r\n" : "hid: panel FAILED\r\n");
                SaveLog();
            }
        } else if (ReadAfterCommand(CMD_READ_ALL, events, sizeof(events))) {
            g_stats[0]++;
            failures = 0;
            for (ULONG i = 0; i < STACK_EVENTS && events[i * EVENT_SIZE] != 0; i++) {
                g_stats[2]++;
                UpdateContact(&events[i * EVENT_SIZE]);
            }
        } else {
            g_stats[1]++;
            if (++failures == PANEL_LOST_READS) {
                LogText("hid: panel lost\r\n");
                SaveLog();
                panel = FALSE;
                failures = 0;
            }
        }
        // Diagnostics: every 10 s during the first 3 minutes, one line in touch.txt.
        if (++polls % 1000 == 0 && polls <= 18000) {
            LogText("hid: reads ");
            for (ULONG i = 0; i < 5; i++) {
                LogHex(g_stats[i], 8);
                LogText(i == 4 ? "\r\n" : " ");
            }
            SaveLog();
        }
        BuildReport();
        PollKeys(polls);
        if (polls % CLOCK_EVERY == 0)
            ClockLearn();
        FlushReports();
    }
    PsTerminateSystemThread(STATUS_SUCCESS);
}

static NTSTATUS StartPolling(VOID)
{
    PHYSICAL_ADDRESS address;
    HANDLE handle;
    NTSTATUS status;

    if (g_thread != NULL)
        return STATUS_SUCCESS;
    address.QuadPart = I2C3_BASE;
    g_i2c = MmMapIoSpace(address, I2C3_SIZE, MmNonCached);
    if (g_i2c == NULL)
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
    PIRP irp;

    if (g_thread == NULL)
        return;
    KeSetEvent(&g_stop, IO_NO_INCREMENT, FALSE);
    KeWaitForSingleObject(g_thread, Executive, KernelMode, FALSE, NULL);
    ObDereferenceObject(g_thread);
    g_thread = NULL;
    MmUnmapIoSpace((PVOID) g_i2c, I2C3_SIZE);
    g_i2c = NULL;
    if (g_screenOff)
        ScreenOn(TRUE);
    if (g_gpio != NULL) {
        MmUnmapIoSpace((PVOID) g_gpio, GPIO_SIZE);
        g_gpio = NULL;
    }
    if (g_i2c5 != NULL) {
        MmUnmapIoSpace((PVOID) g_i2c5, I2C5_SIZE);
        I2c5LockClose();
        g_i2c5 = NULL;
    }
    if (g_pwm != NULL) {
        MmUnmapIoSpace((PVOID) g_pwm, PWM_SIZE);
        g_pwm = NULL;
    }
    if (g_pinmux != NULL) {
        MmUnmapIoSpace((PVOID) g_pinmux, PINMUX_SIZE);
        g_pinmux = NULL;
    }
    if (g_dc != NULL) {
        MmUnmapIoSpace((PVOID) g_dc, DC_SIZE);
        g_dc = NULL;
    }
    if (g_dsi != NULL) {
        MmUnmapIoSpace((PVOID) g_dsi, DSI_SIZE);
        g_dsi = NULL;
    }
    g_pwmMode = FALSE;
    g_oled = FALSE;
    g_keyCount = 0;

    while ((irp = PopRead()) != NULL) {
        irp->IoStatus.Status = STATUS_CANCELLED;
        irp->IoStatus.Information = 0;
        IoCompleteRequest(irp, IO_NO_INCREMENT);
    }
}

static NTSTATUS Copy(PIRP irp, const VOID *data, ULONG size)
{
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(irp);

    if (stack->Parameters.DeviceIoControl.OutputBufferLength < size)
        return STATUS_BUFFER_TOO_SMALL;
    RtlCopyMemory(irp->UserBuffer, data, size);
    irp->IoStatus.Information = size;
    return STATUS_SUCCESS;
}

NTSTATUS DispatchHid(PDEVICE_OBJECT device, PIRP irp)
{
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(irp);
    NTSTATUS status = STATUS_NOT_SUPPORTED;
    HID_DEVICE_ATTRIBUTES attributes;
    KIRQL irql;

    UNREFERENCED_PARAMETER(device);
    irp->IoStatus.Information = 0;
    switch (stack->Parameters.DeviceIoControl.IoControlCode) {
    case IOCTL_HID_GET_DEVICE_DESCRIPTOR:
        status = Copy(irp, &g_hidDescriptor, sizeof(g_hidDescriptor));
        break;
    case IOCTL_HID_GET_REPORT_DESCRIPTOR:
        status = Copy(irp, g_reportDescriptor, sizeof(g_reportDescriptor));
        break;
    case IOCTL_HID_GET_DEVICE_ATTRIBUTES:
        RtlZeroMemory(&attributes, sizeof(attributes));
        attributes.Size = sizeof(attributes);
        attributes.VendorID = VENDOR_ID;
        attributes.ProductID = PRODUCT_ID;
        attributes.VersionNumber = VERSION_NUMBER;
        status = Copy(irp, &attributes, sizeof(attributes));
        break;
    case IOCTL_HID_READ_REPORT:
        if (stack->Parameters.DeviceIoControl.OutputBufferLength < REPORT_SIZE) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        KeAcquireSpinLock(&g_lock, &irql);
        IoMarkIrpPending(irp);
        InsertTailList(&g_reads, &irp->Tail.Overlay.ListEntry);
        IoSetCancelRoutine(irp, CancelRead);
        if (irp->Cancel && IoSetCancelRoutine(irp, NULL) != NULL) {
            RemoveEntryList(&irp->Tail.Overlay.ListEntry);
            KeReleaseSpinLock(&g_lock, irql);
            irp->IoStatus.Status = STATUS_CANCELLED;
            IoCompleteRequest(irp, IO_NO_INCREMENT);
            return STATUS_PENDING;
        }
        KeReleaseSpinLock(&g_lock, irql);
        return STATUS_PENDING;
    case IOCTL_HID_GET_FEATURE: {
        PHID_XFER_PACKET packet = (PHID_XFER_PACKET) irp->UserBuffer;

        if (packet == NULL || packet->reportBuffer == NULL || packet->reportBufferLen < 2) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        if (packet->reportId != REPORT_ID_MAX) {
            status = STATUS_INVALID_PARAMETER;
            break;
        }
        packet->reportBuffer[0] = REPORT_ID_MAX;
        packet->reportBuffer[1] = MAX_CONTACTS;
        irp->IoStatus.Information = 2;
        status = STATUS_SUCCESS;
        break;
    }
    case IOCTL_HID_ACTIVATE_DEVICE:
    case IOCTL_HID_DEACTIVATE_DEVICE:
        status = STATUS_SUCCESS;
        break;
    default:
        break;
    }
    irp->IoStatus.Status = status;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return status;
}

NTSTATUS DispatchPnp(PDEVICE_OBJECT device, PIRP irp)
{
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(irp);
    PDEVICE_OBJECT next = NextDevice(device);
    UCHAR minor = stack->MinorFunction;
    NTSTATUS status;

    switch (minor) {
    case IRP_MN_STOP_DEVICE:
    case IRP_MN_SURPRISE_REMOVAL:
    case IRP_MN_REMOVE_DEVICE:
        StopPolling();
        irp->IoStatus.Status = STATUS_SUCCESS;
        break;
    default:
        break;
    }
    IoSkipCurrentIrpStackLocation(irp);
    status = IoCallDriver(next, irp);
    if (minor == IRP_MN_START_DEVICE)
        StartPolling();
    return status;
}

NTSTATUS DispatchPower(PDEVICE_OBJECT device, PIRP irp)
{
    PoStartNextPowerIrp(irp);
    IoSkipCurrentIrpStackLocation(irp);
    return PoCallDriver(NextDevice(device), irp);
}

NTSTATUS AddDevice(PDRIVER_OBJECT driver, PDEVICE_OBJECT device)
{
    UNREFERENCED_PARAMETER(driver);
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
    HID_MINIDRIVER_REGISTRATION registration;

    KeInitializeSpinLock(&g_lock);
    InitializeListHead(&g_reads);
    KeInitializeEvent(&g_stop, NotificationEvent, FALSE);

    driver->MajorFunction[IRP_MJ_INTERNAL_DEVICE_CONTROL] = DispatchHid;
    driver->MajorFunction[IRP_MJ_PNP] = DispatchPnp;
    driver->MajorFunction[IRP_MJ_POWER] = DispatchPower;
    driver->DriverExtension->AddDevice = AddDevice;
    driver->DriverUnload = Unload;

    RtlZeroMemory(&registration, sizeof(registration));
    registration.Revision = HID_REVISION;
    registration.DriverObject = driver;
    registration.RegistryPath = registry;
    registration.DeviceExtensionSize = 0;
    registration.DevicesArePolled = FALSE;
    return HidRegisterMinidriver(&registration);
}
