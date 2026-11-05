# MC3000 protocol notes

What this project has found, tested on one MC3000 (firmware 1.27, hardware 2.2) unless noted. These are unofficial notes and may not hold for other firmware. See the README's credits for the earlier work this builds on.

Multi-byte values are big-endian. Slots are 0-based for status and program reads, and a bitmask (`1 << slot`) for Bluetooth start, stop and program writes.

## Connections

- **Bluetooth:** service `FFE0`, characteristic `FFE1` (write without response, notify). The charger advertises as `Charger`. Other devices can advertise `FFE0` too, so match the name as well.
- **USB:** HID, VID `0x0000`, PID `0x0001`, product string `STM32 Custm HID`, 64-byte reports, no report IDs.
- **One at a time:** USB stopped answering while Bluetooth was connected, and resumed within a few seconds of disconnecting.

## Bluetooth frames

20 bytes: `0F <op> <args…> <checksum>`. The checksum at byte 19 is the sum of bytes 0–18, masked to `0xFF`.

| Op | Purpose | Argument | Reply |
|---|---|---|---|
| `0x55` | Slot status | slot index | Status |
| `0x56` | Voltage curve | slot index | 246 bytes across several notifications |
| `0x57` | Version | none | Version (its checksum doesn't validate) |
| `0x61` | Charger settings | none | Settings |
| `0x63` | Write settings | see below | Ack, byte 2 = 1 on success |
| `0x05` | Start | slot mask | Ack |
| `0xFE` | Stop | slot mask | Ack |
| `0x11` | Write program | 40 bytes, two 20-byte chunks | Ack |

An ack looks like `0F <op> <mask> F0 FF FF 00…`.

**Stop with mask `0x0F`** stopped all running slots on firmware 1.27, in under a second. Other notes report it only resets the display on some firmware, so confirm with status and fall back to per-slot stops.

**A slot showing Done or a cutoff ignores start** until it's been cleared with a stop.

### Status reply (`0x55`)

| Byte | Field |
|---|---|
| 2 | Slot |
| 3 | Type: 0 Li-ion, 1 LiFePO4, 2 Li-ion 4.35 V, 3 NiMH, 4 NiCd, 5 NiZn, 6 Eneloop, 7 RAM, 8 LTO, 9 Na-ion |
| 4 | Mode: 0 Charge, 1 Refresh, 2 Storage or Break-in, 3 Discharge, 4 Cycle |
| 5 | Cycle count |
| 6 | Status: 0 stand-by, 1 charge, 2 discharge, 3 rest, 4 done, 128 and up are faults |
| 7–8 | Elapsed seconds |
| 9–10 | Voltage, mV |
| 11–12 | Current, mA (always positive) |
| 13–14 | Capacity, mAh |
| 15 | Temperature, °C |
| 16–17 | Internal resistance, mΩ |
| 18 | LED bitmask |

Fault codes seen on hardware: 134 capacity limit, 135 time limit, 137 battery temperature. Others come from the notes: 128 input low, 129 input high, 130 and 131 measurement chips, 132 connection, 133 check voltage, 136 charger temperature, 138 short circuit, 139 polarity.

### Behavior worth knowing

- **Stale fields:** time, capacity and resistance keep their last values while idle.
- **Displayed mode lags:** status keeps the previous mode after a program write, until the slot starts.
- **Capacity resets:** it resets to 0 between phases, and a stopped discharge has also read 0 afterward. Save values before they go.
- **Current dips:** while charging, current dips briefly about every 20 seconds. The main voltage refreshes around those dips, which may be how the charger detects -dV.
- **Ramp time:** charge current reaches its target in about 20 seconds at 1C, and discharge takes about 45 seconds at 1 A.
- **-dV seen working:** on a 1C NiMH charge with a 3 mV setting, voltage peaked at 1.527 V and the charge ended at 1.524 V.

## Program write (`0x11`, Bluetooth)

40 bytes, sent as two 20-byte writes about 50 ms apart. The checksum at byte 39 is the sum of bytes 0–38.

| Byte | Field |
|---|---|
| 2 | Slot mask |
| 3, 4 | Type, mode |
| 5–6 | Capacity limit, mAh (0 is off, and it really does end the run) |
| 7–8, 9–10 | Charge current, discharge current, mA |
| 11–12 | **Charge** stop voltage, mV |
| 13–14 | **Discharge** stop voltage, mV |
| 15–16, 17–18 | Charge end current, discharge end current, mA |
| 19 | **Charge rest**, minutes |
| 20 | **Cycle count** |
| 21 | Cycle order: 0 C>D, 1 C>D>C, 2 D>C, 3 D>C>D |
| 22 | -dV, mV |
| 23 | Trickle current, 10 mA units |
| 24–25 | Keep (restart) voltage, mV |
| 26 | Temperature cutoff, °C |
| 27–28 | Time limit, minutes, for the whole program |
| 29 | Discharge rest, minutes |

Values aren't range-checked. They're stored as sent, and an acknowledged program can't be read back over Bluetooth.

## USB frames

Requests are one 64-byte report: `0F <len> <cmd> <data…> <checksum> FF FF`, where the checksum covers `cmd` and `data`. Reply byte 0 echoes the command.

| Command | Frame | Notes |
|---|---|---|
| Live status | `0F 04 55 00 <slot> <ck> FF FF` | |
| Read program | `0F 04 5F 00 <slot> <ck> FF FF` | |
| System info | `0F 04 5A 00 00 5A FF FF` | Machine ID at bytes 16–21, firmware at 27–28, hardware at 29 |
| Start all | `0F 03 05 00 05 FF FF` | **Global.** No slot-specific form was found. USB replies pause for about 3.4 s afterward |
| Stop all | `0F 03 FE 00 FE FF FF` | **Global** |
| Write program | `0F 20 11 00 <slot> …` | Ack begins `F0` |

A value past the charger's limits resets the slot to Li-ion defaults, and the ack still looks normal. Always read back.

### Live reply (`0x55`)

| Byte | Field |
|---|---|
| 1, 2, 3, 4, 5 | Slot, type, mode, cycle, status |
| 6–7 | Elapsed seconds |
| 8–9 | Voltage, mV |
| 10–11 | Current, mA |
| 12–13 | Capacity, mAh |
| 14–15 | Temperature, 0.1 °C |
| 16–17 | Internal resistance, mΩ |
| 18–19 | Unconfirmed: same across slots and rises over time, possibly charger temperature in 0.1 °C |
| 20–21 | Energy, mWh |
| 22–23 | Power, mW, close to but not exactly V × A. Unreliable when idle |
| 24 | Capacity tenths (confirmed against current × time) |
| 25–26 | Unconfirmed second voltage, mV. Above the main value early in a charge and below it near the end |
| 63 | Checksum: sum of bytes 0–62 |

### Program reply (`0x5F`)

| Byte | Field |
|---|---|
| 1, 2, 3, 4 | Slot, busy, type, mode |
| 5–6, 7–8, 9–10 | Capacity limit, charge current, discharge current |
| 11–12 | **Discharge** stop voltage (the reverse of the Bluetooth write) |
| 13–14 | **Charge** stop voltage |
| 15–16, 17–18 | Charge end current, discharge end current |
| 19, 20 | **Cycle count, charge rest** (also the reverse of Bluetooth) |
| 21, 22, 23 | Cycle order, -dV, trickle |
| 24–25, 26, 27–28 | Keep voltage, temperature cutoff, time limit |
| 29, 30, 31 | Temperature unit, trickle time, discharge rest |

## Limits

These are the ranges in SkyRC's Android app. The charger itself doesn't enforce them.

| Type | Charge stop (default) | Discharge stop (default) | Keep voltage (default) |
|---|---|---|---|
| Li-ion | 4.00–4.25 V (4.20) | 2.50–3.65 V (3.00) | 3.98–4.18 V (4.15) |
| LiFePO4 | 3.40–3.65 V (3.60) | 2.00–3.15 V (2.90) | 3.38–3.58 V (3.55) |
| Li-ion 4.35 V | 4.10–4.40 V (4.35) | 2.65–3.75 V (3.30) | 4.08–4.33 V (4.25) |
| NiMH, NiCd | 1.47–1.80 V (1.65) | 0.50–1.10 V (1.00) | 1.30–1.45 V (1.35) |
| Eneloop | 1.47–1.80 V (1.65) | 0.50–1.00 V (0.90) | 1.30–1.45 V (1.35) |

Other ranges: charge 0.05–3.00 A, discharge 0.05–2.00 A, temperature cutoff 20–70 °C, time limit up to 1,440 minutes, -dV up to 20 mV, rests up to 240 minutes, trickle up to 300 mA, cycles 1–99, capacity up to 50,000 mAh.
