# SD UHS-I for Windows through the shim (plan)

Status: step 1 (DDR50) implemented behind `shim/build.py --uhs`, being tested in a separate Hekate entry.
(3.3 V, 48 MHz, ~21 MB/s) after the base-clock fix in the shim.

## Why the shim

Windows' inbox `sdbus` drives the SDHCI registers itself and does the SD protocol side of UHS
(ACMD41 with S18R, CMD11, CMD6 bus speed, CMD19 tuning). It does not know the Tegra side:

- the I/O rail (MAX77620 LDO2) must go to 1.8 V, the pads must be told (PMC), recalibrated and
  get Schmitt triggers;
- the controller clock comes from the CAR, and hekate changes it per mode (sdbus only changes
  the SDHCI divider, from the base clock it reads in the capabilities).

Every Windows access to the SDMMC1 page already traps into the shim (stage 2), so the shim can
add the Tegra steps at the moment sdbus writes the matching standard register.

## Registers (from hekate bdk/)

- SDMMC1 base 0x700B0000:
  - 0x28 host control 1 / power control (`pwrcon` bits 11:9 voltage, bit 8 on);
  - 0x2C clock control (bit 2 card clock enable, bits 15:8 + 7:6 divider N, SDCLK = base / 2N);
  - 0x3C (bits 31:16 = host control 2: bits 2:0 UHS mode, 4 = DDR50, 3 = SDR104, bit 3 VDD_180,
    bit 6 execute tuning, bit 7 sampling clock select);
  - 0x40 caps0: hardware 0x376CD08C, base clock 208 MHz (shim reports 48 = 0x30 since v0.7.0),
    1.8 V support bit 26;
  - 0x44 caps1: hardware 0x10002F73 (SDR50 bit 0, SDR104 bit 1, DDR50 bit 2 = no).
    UEFI (zsdhost patch) clears SDR50/SDR104 through vendor misc control 0x120 bits 4:3;
    Windows reads 0x10002F70;
  - 0x24 present state: DAT[3:0] level bits 23:20 must read 0xF after the switch;
  - 0x100 vendor clock control: bits 23:16 trim/tap, T210B01 tap = 11;
  - 0x1C0 vendor tuning control 0 (bit 17 TAP_HW_UPDATED);
  - 0x1E0 sdmemcomppadctrl (bit 31 E_INPUT_PWRD);
  - 0x1E4 autocal config (bit 29 enable, bit 31 start; offsets bits 14:8 pull-down,
    6:0 pull-up; T210B01 at 1.8 V: 6 and 6);
  - 0x1EC autocal status (bit 31 active).
- CAR 0x60006000 + 0x150 CLK_SOURCE_SDMMC1: bits 31:29 source (0 = PLLP 408 MHz), bits 7:0
  divider D: rate = 408 * 2 / (D + 2). UEFI leaves D = 15 (48 MHz).
  - hekate per mode: HS 50 MHz / div 1; SDR50 100 / 1; SDR104 200 / 1; DDR50 82 MHz (D = 8,
    81.6 MHz) with SDHCI divider 2 (card clock 40.8 MHz).
- PMC 0x7000E400 + 0xE4 PWR_DET_VAL: bit 12 = SDMMC1 pads at 3.3 V (clear for 1.8 V).
- Pinmux 0x70003000 + 0x00/0x04/0x08/0x0C/0x10/0x14 (SDMMC1 CLK, CMD, DAT3..0): bit 12 Schmitt.
- MAX77620 (I2C5, 0x3C) LDO2: CFG 0x27, bits 5:0 voltage (800 mV + 50 mV steps), 1.8 V = 20,
  3.3 V = 50; bits 7:6 power mode (keep).
- Fallback pad drive (APB_MISC GP_SDMMC1_PAD_CFGPADCTRL), T210B01: (reg & 0xF8080FFF) | 0x808 << 12.

## hekate's 1.8 V switch (sdmmc_enable_low_voltage)

1. LDO2 to 1.8 V, wait 150 us.
2. PMC PWR_DET_VAL &= ~BIT(12).
3. Schmitt triggers on the six SDMMC1 pins.
4. Autocal offsets for 1.8 V (6/6 on B01), then autocal: E_INPUT_PWRD on, start, wait up to 10 ms
   for ACTIVE to clear (else fallback pad values), E_INPUT_PWRD off.
5. Power control to 1.8 V (pwrcon = 0x0A | ON), wait 5 ms, card clock on, wait 1 ms,
   DAT[3:0] must read high.

## Planned shim behaviour (step 1: DDR50 only, test loader first)

- caps1 reads: set DDR50 (bit 2); keep SDR50/SDR104 hidden. caps0 keeps 1.8 V support.
- Host control 2 writes: when VDD_180 goes 0 -> 1, run steps 1-4 above before the write
  reaches the controller; sdbus itself then sets the clock and checks DAT levels.
- Host control 2 writes selecting DDR50 (mode 4): set CAR SDMMC1 to 81.6 MHz (D = 8) with the
  card clock stopped, tap 11, and from then on force the SDHCI divider in clock control writes
  to 2 (N = 1). Any other mode: back to 48 MHz and pass sdbus' divider through.
- Recovery: a failed switch leaves the card unusable until power off. The test lives in a
  separate Hekate entry; the main entry stays at high speed.

Later: SDR104 (CAR 200 MHz, tuning through the standard execute-tuning bit with the Tegra
tuning setup from hekate's sdmmc_tuning_execute).
