// Switch touch screen for Windows: a HID minidriver exposing a touch screen digitizer
// with up to MAX_CONTACTS contacts. Windows rotates the contacts with the screen orientation itself.
// The FTS4 panel returns an event queue (READ_ALL_EVENT); each event carries the finger ID in the
// upper 4 bits of its first byte.
// Reads the panel by polling and only talks to I2C3, address 0x49.
#define TOUCHREAD_CORE_ONLY
#include "../touchread/touchread.c"
#include <hidport.h>

#define VENDOR_ID       0x057E
#define PRODUCT_ID      0x2003
#define VERSION_NUMBER  0x0003
#define REPORT_ID_TOUCH 1
#define REPORT_ID_MAX   2
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

static VOID FlushReports(VOID)
{
    PIRP irp;

    if (InterlockedExchange(&g_dirty, 0) == 0)
        return;
    irp = PopRead();
    if (irp == NULL) {
        InterlockedExchange(&g_dirty, 1);
        return;
    }
    RtlCopyMemory(irp->UserBuffer, g_report, REPORT_SIZE);
    irp->IoStatus.Status = STATUS_SUCCESS;
    irp->IoStatus.Information = REPORT_SIZE;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
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
    SaveLog();

    while (KeWaitForSingleObject(&g_stop, Executive, KernelMode, FALSE, &delay) == STATUS_TIMEOUT) {
        if (ReadAfterCommand(CMD_READ_ALL, events, sizeof(events))) {
            for (ULONG i = 0; i < STACK_EVENTS && events[i * EVENT_SIZE] != 0; i++)
                UpdateContact(&events[i * EVENT_SIZE]);
        }
        BuildReport();
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
        ObReferenceObjectByHandle(handle, THREAD_ALL_ACCESS, *PsThreadType, KernelMode, &g_thread, NULL);
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
