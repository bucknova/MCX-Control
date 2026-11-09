# Other SkyRC chargers: protocol map

> **Mostly untested.** MC-X Control runs the SkyRC MC3000, and the MC5000 for NiMH and Eneloop over Bluetooth. Nothing here adds support for any other device, and the other entries have never been tried on real hardware. Sending the wrong command to a charger can start a charge or change its settings, so treat this as research notes.

This map lists Bluetooth protocol facts for devices handled by the SkyRC Android app, version 2.94. It was built by reading how that app talks to each device. It contains no SkyRC code. SkyRC does not endorse this project.

## How far each entry has been checked

| Level | Meaning |
|---|---|
| **Tested** | Used on real hardware |
| **Partly tested** | Status, stop, and starting a charge or discharge confirmed on real hardware, as noted below |
| **APK only** | Read from the app, never tried on a device |

## Devices

Names are the identifiers used inside the app, and may not match the product name printed on the box. The model ID is the text the device returns to the device-info query.

| App name | Model ID | Family | Level |
|---|---|---|---|
| mc5000 | 100214 | NC/MC | **Partly tested** |
| nc3000 | 100209 | NC/MC | APK only |
| nc2200 | 100181 | NC/MC (own screens and program format) | APK only |
| type228 | 100228 | NC/MC (status `0x9A`) | APK only |
| acc6 | 100132 | Classic | APK only |
| b6evo | 100168 | Classic | APK only |
| b6nano | 100134 | Classic | APK only |
| b6nax | 100174 | Classic | APK only |
| d100 | 100131 | Classic | APK only |
| d1001 | none listed | Classic | APK only |
| d200s | 100146 | Classic | APK only |
| d200nex | 100196 | Classic | APK only |
| d200nexMetal | 100203 | Classic | APK only |
| d260 | 100175 | Classic | APK only |
| d750 | 100201 | Classic | APK only |
| q200 | 100104 | Classic | APK only |
| q200v2 | 100158 | Classic | APK only |
| q200neo | 100197 | Classic | APK only |
| t1000 | 100182 | Classic | APK only |
| type230 | 100230 | Classic | APK only |
| type232 | 100232 | Classic | APK only |
| type222 | 100222 | Not established | APK only |
| BD380 | 600153 | Discharger, own commands | APK only |
| psu650 | 200031 | Power supply, own commands | APK only |

The Classic grouping is inferred: these devices appear to share the app's general charger screens. Individual models may differ, particularly in port count and DC output support.

Product names the app lists for some model IDs: 100104 Q200, 100158 Q200V2, 100132 ACC6, 100146 D200s, 100134 B6nano, 100131 D100, 100168 B6evo, 100175 D260, 100197 Q200 neo, 100196 and 100203 D200 Nex, 100230 D8neo.

The MC3000 is not in this app's device list. It has its own protocol, which is the one MC-X Control implements. LapWiz and FASTLAPS devices are also in the app, but they are lap timers rather than chargers, so they are left out.

## Connecting

- BLE service `FFE0`, characteristic `FFE1`, in the devices checked so far.
- Most commands use one frame: `0F`, length (payload + 2), command, payload, checksum. The checksum is the low byte of the sum of the command and payload bytes.
- Frames over 20 bytes need splitting across writes. This has not been proven from a Mac.
- The device-info query (`0x57`) includes the device's Bluetooth MAC address. macOS doesn't expose MAC addresses, so this query may be unusable from a Mac.
- Some devices appear to need a password check (`0x74`) before the app will open them. The MC5000 returned status without one.

## Classic family

| Command | Code | Data |
|---|---|---|
| Slot status | `0x55` | Slot |
| Read program | `0x5F` | Not decoded |
| Start | `0x0F` | Port, type, cells, mode, currents, voltages, cycle settings |
| Stop | `0xFE` | Port |
| Read system info | `0x5A` | Not decoded |
| Write system info | `0x11` | Not decoded |
| Cell voltages | `0x58` | Not decoded |
| DC output status / set | `0x75` / `0x76` | Set: on/off, voltage, current, protection limits |

Likely `0x55` reply layout, big-endian. The app has several reply variants, so this needs checking per model:

| Bytes | Field |
|---|---|
| 5–6 | Capacity |
| 7–8 | Elapsed |
| 9–10 | Voltage |
| 11–12 | Current |
| 13 | External temperature |
| 14 | Internal temperature |
| 15–16 | Resistance |
| 17 | Status |

## NC/MC family

| Command | Code | Data |
|---|---|---|
| Slot status | `0x91` (type228: `0x9A`) | Slot mask 1, 2, 4, 8 |
| Turbo | `0x92` | Not decoded |
| Read program | `0x93` | Slot index; no MC5000 reply at positions 0–4, including with a slot stopped |
| **Program and start** | `0x94` | 40 bytes; confirmed on the MC5000 for Eneloop charge and discharge. There is no separate start command |
| Write system settings | `0x95` | 17 bytes on the MC5000 |
| Read system settings | `0x96` | `04`; the MC5000 returns 7 data bytes, meanings not confirmed |
| Run history | `0x98` | Slot mask; layout below, confirmed on the MC5000 |
| USB-PD status | `0x9B` | `00`; no MC5000 reply, even with a phone charging from the USB port at 21 W. Expected reply starts: state [4], current [5–6], voltage [7–8], energy [9–12], then runtime |
| Temperature probe limit | `0x99` | Port and max temperature (MC5000) |
| Stop | `0xFE` | Slot mask; confirmed on the MC5000 |

`0x91` reply on the MC5000, confirmed live. The NC3000 appears to match through byte 20.

| Bytes | Field |
|---|---|
| 3 | Slot mask |
| 4–5 | Current, mA |
| 6–7 | Voltage, mV |
| 8–9 | Unconfirmed, may be −ΔV |
| 10–11 | Capacity, mAh |
| 12–15 | Elapsed, seconds |
| 16–17 | Resistance, probably mΩ |
| 18 | Status |
| 19 | Mode |
| 20 | Error |
| 21 | Battery type |

MC5000 status 0 is idle, 2 is charging and 3 is discharging. MC5000 battery type 5 was seen on an Eneloop program, and 0–9 appear to be Li-ion, LiHV, LiFe, NiMH, NiCd, Eneloop, NiZn, RAM, LTO and Na-ion. Those codes differ from the MC3000's.

`0x98` reply on the MC5000, confirmed live. It arrives as several notifications, each with its own checksum.

| Bytes | Field |
|---|---|
| 3 | Slot mask |
| 4, 5 | Total parts, this part |
| 6 | Sample interval, seconds (16 seen) |
| 7 onward | Voltage samples, mV, two bytes each, low byte first |
| Last | Checksum |

The samples cover the whole run so far, so a run can be recovered after a lost connection, at 16-second resolution and for voltage only.

Stopping an MC5000 slot returns `0F 04 FE <mask> 01 <checksum>`, leaves the other slots running, and sets the slot to status 0. It also clears that slot's capacity, elapsed time and history, so save a run's final values before stopping it. Idle voltage stays live and matched the charger's screen.

On the MC5000, the first command after connecting got the short message `0F 04 06 01 01 08` instead of its normal reply in all four correctly framed sessions. Send a throwaway status query first.

`0x94` payload on the MC5000, 40 bytes. The frame is `0F 2A 94`, payload, checksum, 44 bytes in all, sent as 20-byte writes. Pairs are big-endian. Only Eneloop charge and discharge at 200 mA have been tried on hardware; other fields and modes come from the app.

| Bytes | Field | Unit | App's range |
|---|---|---|---|
| 0 | Slot **mask** 1, 2, 4, 8, the same as status and stop | | |
| 1 | Mode (below) | | |
| 2–3 | Charge current | mA | 50–5,000, step 50 |
| 4–5 | Discharge current | mA | 50–2,000, step 50 |
| 6–7 | Capacity | mAh | 100–10,000, step 100 |
| 8–9 | Charge stop voltage | mV | Depends on cell type |
| 10–11 | Discharge stop voltage | mV | Depends on cell type |
| 12–13 | Charge end current | mA | 0–990, step 10 |
| 14–15 | Discharge end current | mA | 0–990, step 10; 0 sends the discharge current instead |
| 16–17 | Rest after charge | minutes | 1–120 |
| 18–19 | Rest after discharge | minutes | 1–120 |
| 20 | Cycle count | | Up to 3 in the range I could read; unconfirmed |
| 21 | Cycle mode: 0 C→D, 1 D→C, 2 C→D→C, 3 D→C→D | | |
| 22 | −ΔV | mV | 3–12 |
| 23 | Trickle current ÷ 10 | 10 mA | 50–300 mA |
| 24–25 | Restart voltage | mV | |
| 26 | Temperature protection | °C | The app sends 71 if this is 0 |
| 27–28 | Time limit | minutes | 0–1,440, step 30 |
| 29–30 | Max capacity | Unconfirmed | |
| 31 | Turbo | | |
| 32 | Cell type, 0–9 as in the `0x91` table | | |
| 33–34 | Storage voltage | mV | |
| 35 | Eneloop type: 0 Std AA, 1 Std AAA, 2 Pro/XX AA, 3 Pro/XX AAA, 4 Lite AA, 5 Lite AAA, 6 Plus AA, 7 Std C, 8 Std D | | |

Modes depend on cell type:

| Cell types | Mode 0 | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| Li-ion, LiHV, LiFe, LTO, Na-ion | Charge | Storage | Discharge | Cycle | |
| NiMH, NiCd, Eneloop | Charge | Refresh | Break-in | Discharge | Cycle |
| NiZn | Charge | Discharge | Cycle | | |

Writing this frame starts the slot. The MC5000 answers `0F 04 94 <mask> 01 <checksum>`, and current appears about 4 seconds later. A wrong mask is still acknowledged and simply starts nothing if those slots are busy, so confirm a start from `0x91`. Which cell types use each mode list above is partly inferred; RAM isn't placed yet.

On the MC5000, cell temperature comes from a separate Bluetooth probe, and the app appears to send the over-temperature stop itself. That protection may only work while the phone app is connected.

## BD380 and PSU650

**BD380 (discharger):** `0x71` status, `0x70` start, `0x72` and `0x73` write and read system settings, `0xFE` stop. Its status reply has its own layout.

**PSU650 (power supply):** uses its own command set, and some frames use a different checksum. Not decoded here.

## Never send

These commands exist in the app and can damage or lock a device. MC-X Control should never implement them:

- Firmware update: `0x60`, `0x61`, `0x62`, `0x66`, and any writes to the Telink update service `00010203-0405-0607-0809-0A0B0C0D1912`.
- Reset and factory settings: `0x97`, and the PSU650 factory reset commands.
- Password changes: `0x56`.
- Unknown command codes. Guessing is how a charger gets bricked.

## Testing a new device

If you add a device, start with read-only status and confirm the values against the charger's screen. Prove stop works before trying to start anything, and use a low current and a spare cell for the first start.
