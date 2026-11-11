// Читает идентификатор контроллера сенсора и пишет результат в D:\agent\touch.txt.
// Работает только с шиной I2C3 и только с адресом сенсора.
#include <ntddk.h>

#define I2C3_BASE       0x7000C500ULL
#define I2C3_SIZE       0x100
#define TOUCH_ADDR      0x49
#define CMD_HW_REG_READ 0xB6
#define REG_CHIP_ID     0x04
#define CHIP_ID_SIZE    7

#define R_CNFG          (0x00 / 4)
#define R_CMD_ADDR0     (0x04 / 4)
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
#define FIFO_FLUSH      3
#define RX_FIFO_COUNT   0xF
#define LOAD_ALL        ((1 << 5) | (1 << 2) | 1)
#define MASTER_LOAD     1
#define PROT_I2C        (1 << 4)
#define HDR_REP_START   (1 << 16)
#define HDR_READ        (1 << 19)
#define POLL_US         10
#define POLL_LIMIT      20000
#define LOG_SIZE        256

DRIVER_INITIALIZE DriverEntry;

static CHAR g_log[LOG_SIZE];
static ULONG g_len;

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

static VOID LoadConfig(volatile ULONG *i2c)
{
    i2c[R_CONFIG_LOAD] = LOAD_ALL;
    for (ULONG i = 0; i < 20 && (i2c[R_CONFIG_LOAD] & MASTER_LOAD); i++)
        KeStallExecutionProcessor(1);
}

static BOOLEAN TransferReg(volatile ULONG *i2c, UCHAR reg, UCHAR *rx, ULONG rxSize)
{
    ULONG addr = TOUCH_ADDR << 1;
    ULONG word = CMD_HW_REG_READ | ((ULONG) reg << 16);
    ULONG txSize = 3;
    ULONG received = 0;
    ULONG poll;
    BOOLEAN ok = TRUE;

    i2c[R_CMD_ADDR0] = addr | ADDR0_READ;
    i2c[R_CNFG] = DEBOUNCE_4T | NEW_MASTER_FSM | CMD1_READ;
    i2c[R_FIFO_CONTROL] = FIFO_FLUSH;
    LoadConfig(i2c);
    i2c[R_CNFG] = (i2c[R_CNFG] & ~NORMAL_GO) | PACKET_GO;

    i2c[R_TX_FIFO] = PROT_I2C;
    i2c[R_TX_FIFO] = txSize - 1;
    i2c[R_TX_FIFO] = HDR_REP_START | addr;
    i2c[R_TX_FIFO] = word;

    for (poll = 0; ((i2c[R_PKT_STATUS] >> 4) & 0xFFF) != txSize - 1; poll++) {
        if (poll == POLL_LIMIT) {
            ok = FALSE;
            goto out;
        }
        KeStallExecutionProcessor(POLL_US);
    }

    i2c[R_TX_FIFO] = PROT_I2C;
    i2c[R_TX_FIFO] = rxSize - 1;
    i2c[R_TX_FIFO] = HDR_READ | addr;

    for (poll = 0; received < rxSize; poll++) {
        if (i2c[R_FIFO_STATUS] & RX_FIFO_COUNT) {
            ULONG value = i2c[R_RX_FIFO];
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
    if (i2c[R_STATUS] & STATUS_NOACK)
        ok = FALSE;
    KeStallExecutionProcessor(20);
    i2c[R_CNFG] &= ~(PACKET_GO | NORMAL_GO);
    return ok;
}

static VOID WriteLog(VOID)
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

NTSTATUS DriverEntry(PDRIVER_OBJECT driver, PUNICODE_STRING registry)
{
    PHYSICAL_ADDRESS address;
    volatile ULONG *i2c;
    UCHAR rx[CHIP_ID_SIZE] = { 0 };
    BOOLEAN ok;

    UNREFERENCED_PARAMETER(driver);
    UNREFERENCED_PARAMETER(registry);

    address.QuadPart = I2C3_BASE;
    i2c = MmMapIoSpace(address, I2C3_SIZE, MmNonCached);
    if (i2c == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;

    ok = TransferReg(i2c, REG_CHIP_ID, rx, CHIP_ID_SIZE);
    LogText(ok ? "transfer=ok" : "transfer=fail");
    LogText(" status=");
    LogHex(i2c[R_STATUS], 8);
    LogText(" chip_id=");
    LogHex(((ULONG) rx[1] << 8) | rx[2], 4);
    LogText(" bytes=");
    for (ULONG i = 0; i < CHIP_ID_SIZE; i++)
        LogHex(rx[i], 2);
    LogText("\r\n");

    MmUnmapIoSpace((PVOID) i2c, I2C3_SIZE);
    WriteLog();
    return STATUS_SUCCESS;
}
