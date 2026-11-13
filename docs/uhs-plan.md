# SD UHS-I for Windows through the shim (plan)

Status: SDR104 released in v0.7.1 (Windows 11 loader, `shim/build.py --uhs sdr104`). The other
variants (`ddr50`, `sdr50-48`, `sdr50`) stay for testing in a separate Hekate entry.

Results:
- `ddr50` (2026-11-13): Windows stops at UNMOUNTABLE_BOOT_VOLUME, status 0xC0000483 (device
  hardware error): sdbus took DDR50, then the card failed. Linux does not enable DDR50 on
  Tegra210 at all (only SDR50/SDR104), so DDR50 is dropped.
- `sdr50-48`: SDR50 (run as SDR104 per the T210 errata, tap 11, no tuning) with the clock left at
  48 MHz. No speed gain; it only checks that the 1.8 V switch works. Next: 100 MHz, then SDR104.
  First build hung the early UEFI (squares 2 and 6): the new code sat inside the trap handler
  and moved it. Rebuilt the Test C way: the old shim keeps every address, four instructions
  change (adr payload, bl uhs_boot_init, b uhs_pre, b.ne uhs_read) and the new code follows it.
  Rebuilt `sdr50-48` (2026-11-13): Windows boots, 20.4 MB/s, 1464 random 4K/s. Windows logs
  nothing about the bus mode, so the speed of the next step is the proof of 1.8 V.
- `sdr50`: SDR50 with SDMMC1 at 90.7 MHz from PLLP (divider 7; hekate takes 99.84 MHz from
  PLLC4, which UEFI may not run) and sdbus' own tuning: the shim sets up the Tegra hardware
  tuning (hekate's sdmmc_tuning_execute for SDR50: 256 tries, step 1, 1x) when sdbus sets
  execute tuning.
  Result (2026-11-13): works. Sequential 36.5 MB/s (was 20.7), 1611 random 4K/s (was 1302),
  boot to the agent 131 s, no disk errors in the System log.
- `sdr104`: SDR50 also reported as SDR104; SDR104 runs SDMMC1 at 204 MHz from PLLP (divider 2;
  hekate: 199.68 MHz from PLLC4), tuning with 128 tries.
  Result (2026-11-13): works. Sequential 68.9 MB/s (3.3x the 20.7 of high speed), 1689 random
  4K/s, boot to the agent 118 s, no disk errors in the System log.
The main entry runs the card in high speed (3.3 V, 48 MHz, ~21 MB/s) after the base-clock fix.

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

## Shim counters (swbatt log, 2026-11-13, SDR104 loader with the hand-off probe)

- Trapped SD register accesses: about 5000 per second at idle, about 7000 per second over a
  minute that includes the read test. Even at a few microseconds per trap that is around 1 % of
  one core, so replacing the full-page trap is not worth its risk for speed.
- `hostctl2` = 0x800B: SDR104, 1.8 V and Preset Value Enable (bit 15) set by sdbus.
- One voltage switch per boot, no autocalibration timeout.
- PMIC at the UEFI hand-off: LDO6 = 0xE8 (2.8 V) after a reboot, 0xC4 (1.0 V) after a cold
  start; LDO2 = 0xF2 (3.3 V). The touch panel needs 2.9 V; the shim now sets it at the hand-off
  (swhid also checks it).
- Read test: 71.4 MB/s sequential, 1532 random 4K/s.
