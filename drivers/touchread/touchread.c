// Включает режим сенсора и минуту пишет касания в D:\agent\touch.txt.
// Работает только с шиной I2C3 и только с адресом сенсора.
#include <ntddk.h>

#define I2C3_BASE       0x7000C500ULL
#define I2C3_SIZE       0x100
#define TOUCH_ADDR      0x49

#define R_CNFG          (0x00 / 4)
#define R_CMD_ADDR0     (0x04 / 4)
#define R_CMD_DATA1     (0x0C / 4)
#define R_CMD_DATA2     (0x10 / 4)
#define R_STATUS        (0x1C / 4)
#define R_TX_FIFO       (0x50 / 4)
#define R_RX_FIFO       (0x54 / 4)
#define R_PKT_STATUS    (0x58 / 4)
#define R_FIFO_CONTROL  (0x5C / 4)
#define R_FIFO_STATUS   (0x60 / 4)
#define R_CONFIG_LOAD   (0x8C / 4)

#define ADDR0_READ      1
#define CMD1_READ       (1 << 6)
#define NORMAL_GO       (1 << 9)
#define PACKET_GO       (1 << 10)
#define NEW_MASTER_FSM  (1 << 11)
#define DEBOUNCE_4T     (2 << 12)
#define STATUS_NOACK    0xF
#define STATUS_BUSY     (1 << 8)
#define FIFO_FLUSH      3
#define RX_FIFO_COUNT   0xF
#define LOAD_ALL        ((1 << 5) | (1 << 2) | 1)
#define MASTER_LOAD     1
#define PROT_I2C        (1 << 4)
#define HDR_REP_START   (1 << 16)
#define HDR_READ        (1 << 19)
#define POLL_US         10
#define POLL_LIMIT      20000

#define CMD_READ_ONE    0x85
#define CMD_LATEST      0x87
#define CMD_SENSE_ON    0x93
#define CMD_CLEAR       0xA1
#define CMD_HW_WRITE    0xB6
#define CMD_SENSE_MODE  0xC3
#define FINGER_MODE     1
#define REG_SYS_RESET   0x28
#define SYS_RESET_VALUE 0x80
#define EVENT_SIZE      8
#define EV_ID_MASK      0x0F
#define EV_ENTER        3
#define EV_LEAVE        4
#define EV_MOTION       5
#define EV_READY        0x10
#define READY_TRIES     40
#define READY_MS        5
#define RESET_MS        10
#define SAMPLE_MS       20
#define SAMPLES         3000
#define SAVE_EVERY      250
#define MOTION_EVERY    8
#define LOG_SIZE        16384

#ifndef TOUCHREAD_CORE_ONLY
DRIVER_INITIALIZE DriverEntry;
KSTART_ROUTINE ReadThread;
#endif

static CHAR g_log[LOG_SIZE];
static ULONG g_len;
static volatile ULONG *g_i2c;

static VOID LogText(const CHAR *text)
{
    while (*text != 0 && g_len < LOG_SIZE - 1)
        g_log[g_len++] = *text++;
}

static VOID LogHex(ULONG value, ULONG digits)
{
    static const CHAR hex[] = "0123456789ABCDEF";

    while (digits-- > 0 && g_len < LOG_SIZE - 1)
        g_log[g_len++] = hex[(value >> (digits * 4)) & 0xF];
}

static VOID SleepMs(ULONG ms)
{
    LARGE_INTEGER delay;

    delay.QuadPart = -10000LL * ms;
    KeDelayExecutionThread(KernelMode, FALSE, &delay);
}

static VOID LoadConfig(VOID)
{
    g_i2c[R_CONFIG_LOAD] = LOAD_ALL;
    for (ULONG i = 0; i < 20 && (g_i2c[R_CONFIG_LOAD] & MASTER_LOAD); i++)
        KeStallExecutionProcessor(1);
}

static BOOLEAN Send(const UCHAR *data, ULONG size)
{
    ULONG words[2] = { 0, 0 };
    ULONG poll;

    if (size == 0 || size > 8)
        return FALSE;
    for (ULONG i = 0; i < size; i++)
        words[i / 4] |= (ULONG) data[i] << ((i % 4) * 8);

    g_i2c[R_CMD_ADDR0] = TOUCH_ADDR << 1;
    g_i2c[R_CMD_DATA1] = words[0];
    g_i2c[R_CMD_DATA2] = words[1];
    g_i2c[R_CNFG] = ((size - 1) << 1) | DEBOUNCE_4T | NEW_MASTER_FSM;
    LoadConfig();
    g_i2c[R_CNFG] = (g_i2c[R_CNFG] & ~NORMAL_GO) | NORMAL_GO;

    for (poll = 0; g_i2c[R_STATUS] & STATUS_BUSY; poll++) {
        if (poll == POLL_LIMIT)
            return FALSE;
        KeStallExecutionProcessor(POLL_US);
    }
    return (g_i2c[R_STATUS] & STATUS_NOACK) == 0;
}

static BOOLEAN ReadAfterCommand(UCHAR command, UCHAR *rx, ULONG rxSize)
{
    ULONG addr = TOUCH_ADDR << 1;
    ULONG received = 0;
    ULONG poll;
    BOOLEAN ok = TRUE;

    g_i2c[R_CMD_ADDR0] = addr | ADDR0_READ;
    g_i2c[R_CNFG] = DEBOUNCE_4T | NEW_MASTER_FSM | CMD1_READ;
    g_i2c[R_FIFO_CONTROL] = FIFO_FLUSH;
    LoadConfig();
    g_i2c[R_CNFG] = (g_i2c[R_CNFG] & ~NORMAL_GO) | PACKET_GO;

    g_i2c[R_TX_FIFO] = PROT_I2C;
    g_i2c[R_TX_FIFO] = 0;
    g_i2c[R_TX_FIFO] = HDR_REP_START | addr;
    g_i2c[R_TX_FIFO] = command;

    for (poll = 0; ((g_i2c[R_PKT_STATUS] >> 4) & 0xFFF) != 0; poll++) {
        if (poll == POLL_LIMIT) {
            ok = FALSE;
            goto out;
        }
        KeStallExecutionProcessor(POLL_US);
    }

    g_i2c[R_TX_FIFO] = PROT_I2C;
    g_i2c[R_TX_FIFO] = rxSize - 1;
    g_i2c[R_TX_FIFO] = HDR_READ | addr;

    for (poll = 0; received < rxSize; poll++) {
        if (g_i2c[R_FIFO_STATUS] & RX_FIFO_COUNT) {
            ULONG value = g_i2c[R_RX_FIFO];
            for (ULONG n = 0; n < 4 && received < rxSize; n++)
                rx[received++] = (UCHAR) (value >> (n * 8));
        }
        if (poll == POLL_LIMIT) {
            ok = FALSE;
            break;
        }
        KeStallExecutionProcessor(POLL_US);
    }

out:
    if (g_i2c[R_STATUS] & STATUS_NOACK)
        ok = FALSE;
    KeStallExecutionProcessor(20);
    g_i2c[R_CNFG] &= ~(PACKET_GO | NORMAL_GO);
    return ok;
}

static VOID SaveLog(VOID)
{
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES attributes;
    IO_STATUS_BLOCK io;
    HANDLE file;

    RtlInitUnicodeString(&name, L"\\??\\D:\\agent\\touch.txt");
    InitializeObjectAttributes(&attributes, &name, OBJ_KERNEL_HANDLE | OBJ_CASE_INSENSITIVE, NULL, NULL);
    if (NT_SUCCESS(ZwCreateFile(&file, GENERIC_WRITE | SYNCHRONIZE, &attributes, &io, NULL,
            FILE_ATTRIBUTE_NORMAL, 0, FILE_OVERWRITE_IF, FILE_SYNCHRONOUS_IO_NONALERT, NULL, 0))) {
        ZwWriteFile(file, NULL, NULL, NULL, &io, g_log, g_len, NULL, NULL);
        ZwFlushBuffersFile(file, &io);
        ZwClose(file);
    }
}

static BOOLEAN InitPanel(VOID)
{
    static const UCHAR reset[] = { CMD_HW_WRITE, 0, REG_SYS_RESET, SYS_RESET_VALUE };
    static const UCHAR mode[] = { CMD_SENSE_MODE, FINGER_MODE };
    static const UCHAR senseOn[] = { CMD_SENSE_ON };
    static const UCHAR clear[] = { CMD_CLEAR };
    UCHAR event[EVENT_SIZE];
    BOOLEAN ready = FALSE;

    if (!Send(reset, sizeof(reset))) {
        LogText("reset=fail\r\n");
        return FALSE;
    }
    SleepMs(RESET_MS);
    for (ULONG i = 0; i < READY_TRIES && !ready; i++) {
        ready = ReadAfterCommand(CMD_READ_ONE, event, EVENT_SIZE) && event[0] == EV_READY;
        if (!ready)
            SleepMs(READY_MS);
    }
    LogText(ready ? "ready=ok\r\n" : "ready=timeout\r\n");

    if (!Send(mode, sizeof(mode)) || !Send(senseOn, sizeof(senseOn)) || !Send(clear, sizeof(clear))) {
        LogText("sense=fail\r\n");
        return FALSE;
    }
    LogText("sense=ok\r\n");
    return TRUE;
}

#ifndef TOUCHREAD_CORE_ONLY
VOID ReadThread(PVOID context)
{
    UCHAR event[EVENT_SIZE];
    ULONG motion = 0;
    ULONG failures = 0;

    UNREFERENCED_PARAMETER(context);
    if (InitPanel()) {
        for (ULONG i = 0; i < SAMPLES; i++) {
            if (ReadAfterCommand(CMD_LATEST, event, EVENT_SIZE)) {
                ULONG id = event[0] & EV_ID_MASK;

                if (id == EV_ENTER || id == EV_LEAVE || (id == EV_MOTION && ++motion % MOTION_EVERY == 0)) {
                    LogText(id == EV_ENTER ? "down " : id == EV_LEAVE ? "up   " : "move ");
                    LogHex(((ULONG) event[1] << 4) | (event[3] >> 4), 3);
                    LogText(" ");
                    LogHex(((ULONG) event[2] << 4) | (event[3] & 0xF), 3);
                    LogText("\r\n");
                }
            } else {
                failures++;
            }
            if (i % SAVE_EVERY == 0)
                SaveLog();
            SleepMs(SAMPLE_MS);
        }
        LogText("end failures=");
        LogHex(failures, 8);
        LogText("\r\n");
    }
    SaveLog();
    MmUnmapIoSpace((PVOID) g_i2c, I2C3_SIZE);
    PsTerminateSystemThread(STATUS_SUCCESS);
}

NTSTATUS DriverEntry(PDRIVER_OBJECT driver, PUNICODE_STRING registry)
{
    PHYSICAL_ADDRESS address;
    HANDLE thread;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(driver);
    UNREFERENCED_PARAMETER(registry);

    address.QuadPart = I2C3_BASE;
    g_i2c = MmMapIoSpace(address, I2C3_SIZE, MmNonCached);
    if (g_i2c == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;

    status = PsCreateSystemThread(&thread, THREAD_ALL_ACCESS, NULL, NULL, NULL, ReadThread, NULL);
    if (NT_SUCCESS(status))
        ZwClose(thread);
    return status;
}
#endif // TOUCHREAD_CORE_ONLY
