// Проба без WDF: проверяет только загрузку и подпись. Рисует жёлтую метку.
#include <ntddk.h>

#define FB_PHYSICAL 0xF5A00000ULL
#define FB_STRIDE   720
#define FB_HEIGHT   1280
#define FB_SIZE     (FB_STRIDE * FB_HEIGHT * 4)
#define MARK_X      260
#define MARK_Y      300
#define MARK_SIZE   200
#define COLOR       0xFFFFFF00
#define REDRAWS     240
#define REDRAW_MS   500
#define PWM_CSR1    0x7000A010ULL
#define PWM_FULL    0x80000000  // инверсия: нулевая ширина импульса — полная скорость

DRIVER_INITIALIZE DriverEntry;
KSTART_ROUTINE MarkThread;

static VOID DrawMark(volatile ULONG *fb)
{
    for (ULONG y = MARK_Y; y < MARK_Y + MARK_SIZE; y++)
        for (ULONG x = MARK_X; x < MARK_X + MARK_SIZE; x++)
            fb[y * FB_STRIDE + x] = COLOR;
}

VOID MarkThread(PVOID context)
{
    volatile ULONG *fb = context;
    LARGE_INTEGER delay;

    delay.QuadPart = -10000LL * REDRAW_MS;
    for (ULONG i = 0; i < REDRAWS; i++) {
        DrawMark(fb);
        KeDelayExecutionThread(KernelMode, FALSE, &delay);
    }
    MmUnmapIoSpace((PVOID) fb, FB_SIZE);
    PsTerminateSystemThread(STATUS_SUCCESS);
}

NTSTATUS DriverEntry(PDRIVER_OBJECT driver, PUNICODE_STRING registry)
{
    PHYSICAL_ADDRESS address;
    volatile ULONG *fb;
    volatile ULONG *pwm;
    HANDLE thread;

    UNREFERENCED_PARAMETER(driver);
    UNREFERENCED_PARAMETER(registry);
    address.QuadPart = PWM_CSR1;
    pwm = MmMapIoSpace(address, sizeof(ULONG), MmNonCached);
    if (pwm != NULL) {
        *pwm = PWM_FULL;  // слышимый признак того, что драйвер запущен
        MmUnmapIoSpace((PVOID) pwm, sizeof(ULONG));
    }

    address.QuadPart = FB_PHYSICAL;
    fb = MmMapIoSpace(address, FB_SIZE, MmNonCached);
    if (fb == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;
    DrawMark(fb);
    return PsCreateSystemThread(&thread, THREAD_ALL_ACCESS, NULL, NULL, NULL, MarkThread, (PVOID) fb);
}
