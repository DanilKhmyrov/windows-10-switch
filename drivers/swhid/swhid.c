// Switch touch screen for Windows: a HID minidriver exposing a touch screen digitizer
// with up to MAX_CONTACTS contacts. Windows rotates the contacts with the screen orientation itself.
// The FTS4 panel returns an event queue (READ_ALL_EVENT); each event carries the finger ID in the
// upper 4 bits of its first byte.
// Reads the panel by polling and only talks to I2C3, address 0x49.
// The volume buttons (PX6 = up, PX7 = down, low = pressed, as Switchroot's nx-keys) are read on
// the same poll and reported as a second top-level collection, Consumer Control (Volume
// Increment / Decrement), so Windows changes the volume and shows its volume flyout.
// The power button (MAX77620 ONOFFSTAT EN0 on I2C5) is polled too:
//   short press: backlight off/on (PWM channel 0, as hekate); touch is ignored while it is off;
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

static VOID Backlight(ULONG duty)
{
    if (g_pwm != NULL)
        g_pwm[PWM_CSR0] = PWM_ENABLE | (duty << 16);
}

static VOID ScreenOn(BOOLEAN on)
{
    g_screenOff = !on;
    Backlight(on ? g_duty : 0);
}

static VOID Brightness(LONG step)
{
    LONG duty = (LONG) g_duty + step;

    g_duty = (ULONG) (duty < BRIGHT_MIN ? BRIGHT_MIN : duty > 255 ? 255 : duty);
    ScreenOn(TRUE);
}

// ---- Buttons -----------------------------------------------------------------------

// Volume: two equal samples (20 ms) make a change; held, one more release/press pair every
// KEY_STEP_MS after KEY_REPEAT_MS. Power (read every 50 ms): see the top of the file.
static VOID PollKeys(ULONG polls)
{
    static UCHAR last, stable, sent;
    static ULONG heldMs, powerMs;
    static BOOLEAN power, combo, powerSent;
    ULONG in;
    UCHAR now;

    if (g_gpio == NULL)
        return;
    if (g_i2c5 != NULL && polls % POWER_EVERY == 0) {
        UCHAR status;

        if (P5Read(PMIC_ADDR, PMIC_ONOFFSTAT, &status))
            power = (status & PMIC_EN0) != 0;
    }
    if (power) {
        powerMs += POLL_MS;
        if (!combo && !powerSent && powerMs >= POWER_HOLD_MS) {
            QueueReport(REPORT_ID_SAS, 1);
            QueueReport(REPORT_ID_SAS, 0);
            powerSent = TRUE;
        }
    } else if (powerMs != 0) {
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
    address.QuadPart = PWM_BASE;
    g_pwm = MmMapIoSpace(address, PWM_SIZE, MmNonCached);
    if (g_pwm != NULL) {
        g_duty = (g_pwm[PWM_CSR0] >> 16) & 0xFF;
        if (g_duty < BRIGHT_MIN)
            g_duty = 150;
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
    LogText(InitPanel() ? "hid: panel ok\r\n" : "hid: panel FAILED\r\n");
    StartKeys();
    SaveLog();

    ULONG polls = 0;

    while (KeWaitForSingleObject(&g_stop, Executive, KernelMode, FALSE, &delay) == STATUS_TIMEOUT) {
        if (ReadAfterCommand(CMD_READ_ALL, events, sizeof(events))) {
            g_stats[0]++;
            for (ULONG i = 0; i < STACK_EVENTS && events[i * EVENT_SIZE] != 0; i++) {
                g_stats[2]++;
                UpdateContact(&events[i * EVENT_SIZE]);
            }
        } else {
            g_stats[1]++;
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
        g_i2c5 = NULL;
    }
    if (g_pwm != NULL) {
        MmUnmapIoSpace((PVOID) g_pwm, PWM_SIZE);
        g_pwm = NULL;
    }
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
