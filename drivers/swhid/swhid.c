// Switch touch screen for Windows: a HID minidriver exposing a touch screen digitizer
// with up to MAX_CONTACTS contacts. Windows rotates the contacts with the screen orientation itself.
// The FTS4 panel returns an event queue (READ_ALL_EVENT); each event carries the finger ID in the
// upper 4 bits of its first byte.
// Reads the panel by polling and only talks to I2C3, address 0x49.
// The volume buttons (PX6 = up, PX7 = down, low = pressed, as Switchroot's nx-keys) are read on
// the same poll and reported as a second top-level collection, Consumer Control (Volume
// Increment / Decrement), so Windows changes the volume and shows its volume flyout.
#define TOUCHREAD_CORE_ONLY
#include "../touchread/touchread.c"
#include <hidport.h>

#define VENDOR_ID       0x057E
#define PRODUCT_ID      0x2003
#define VERSION_NUMBER  0x0004
#define REPORT_ID_TOUCH 1
#define REPORT_ID_MAX   2
#define REPORT_ID_KEYS  3
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
    0xC0
};

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

static VOID QueueKeys(UCHAR state)
{
    if (g_keyCount < KEY_QUEUE) {
        g_keyQueue[(g_keyHead + g_keyCount) % KEY_QUEUE] = state;
        g_keyCount++;
    }
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
        buffer[0] = REPORT_ID_KEYS;
        buffer[1] = g_keyQueue[g_keyHead];
        g_keyHead = (g_keyHead + 1) % KEY_QUEUE;
        g_keyCount--;
        g_stats[4]++;
        irp->IoStatus.Status = STATUS_SUCCESS;
        irp->IoStatus.Information = KEY_REPORT_SIZE;
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

// Volume buttons: two equal samples (20 ms) make a change. A held button sends one more
// release/press pair every KEY_STEP_MS after KEY_REPEAT_MS, so the volume keeps moving.
static VOID PollKeys(VOID)
{
    static UCHAR last, stable;
    static ULONG heldMs;
    ULONG in;
    UCHAR now;

    if (g_gpio == NULL)
        return;
    in = g_gpio[GPIO_PX_IN];
    now = (UCHAR) (((in & PX_VOL_UP) ? 0 : 1) | ((in & PX_VOL_DOWN) ? 0 : 2));
    if (now != last) {
        last = now;
        return;
    }
    if (now != stable) {
        stable = now;
        heldMs = 0;
        QueueKeys(now);
        return;
    }
    if (stable == 0)
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
        PollKeys();
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
    if (g_gpio != NULL) {
        MmUnmapIoSpace((PVOID) g_gpio, GPIO_SIZE);
        g_gpio = NULL;
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
