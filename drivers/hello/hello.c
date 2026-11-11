// Проба: Windows приняла наш драйвер? Рисует метку в кадровом буфере и больше ничего.
#include <ntddk.h>
#include <wdf.h>

#define FB_PHYSICAL 0xF5A00000ULL
#define FB_STRIDE   720
#define FB_HEIGHT   1280
#define FB_SIZE     (FB_STRIDE * FB_HEIGHT * 4)
#define MARK_X      260
#define MARK_Y      40
#define MARK_SIZE   200
#define COLOR_OK    0xFF00FF00  // зелёный: драйвер загружен, WDF подключена
#define COLOR_FAIL  0xFFFF00FF  // пурпурный: WDF вернула ошибку
#define REDRAWS     240
#define REDRAW_MS   500

DRIVER_INITIALIZE DriverEntry;
KSTART_ROUTINE MarkThread;

static ULONG g_color;

static VOID DrawMark(volatile ULONG *fb)
{
    for (ULONG y = MARK_Y; y < MARK_Y + MARK_SIZE; y++)
        for (ULONG x = MARK_X; x < MARK_X + MARK_SIZE; x++)
            fb[y * FB_STRIDE + x] = g_color;
}

VOID MarkThread(PVOID context)
{
    PHYSICAL_ADDRESS address;
    LARGE_INTEGER delay;
    volatile ULONG *fb;

    UNREFERENCED_PARAMETER(context);
    address.QuadPart = FB_PHYSICAL;
    delay.QuadPart = -10000LL * REDRAW_MS;
    fb = MmMapIoSpace(address, FB_SIZE, MmNonCached);
    if (fb != NULL) {
        for (ULONG i = 0; i < REDRAWS; i++) {
            DrawMark(fb);
            KeDelayExecutionThread(KernelMode, FALSE, &delay);
        }
        MmUnmapIoSpace((PVOID) fb, FB_SIZE);
    }
    PsTerminateSystemThread(STATUS_SUCCESS);
}

NTSTATUS DriverEntry(PDRIVER_OBJECT driver, PUNICODE_STRING registry)
{
    WDF_DRIVER_CONFIG config;
    HANDLE thread;
    NTSTATUS status;

    WDF_DRIVER_CONFIG_INIT(&config, WDF_NO_EVENT_CALLBACK);
    config.DriverInitFlags = WdfDriverInitNonPnpDriver;
    status = WdfDriverCreate(driver, registry, WDF_NO_OBJECT_ATTRIBUTES, &config, WDF_NO_HANDLE);
    g_color = NT_SUCCESS(status) ? COLOR_OK : COLOR_FAIL;

    return PsCreateSystemThread(&thread, THREAD_ALL_ACCESS, NULL, NULL, NULL, MarkThread, NULL);
}
