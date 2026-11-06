# MC-X Control

A native macOS app for monitoring, controlling and benchmarking the **SkyRC MC3000** battery charger and analyzer, over USB or Bluetooth.

SkyRC doesn't ship Mac software for this charger, so this project fills the gap. It's written in SwiftUI with Liquid Glass and needs nothing beyond Apple's Command Line Tools to build.

> **Not affiliated with or endorsed by SkyRC.** MC3000 and SkyRC are their owners' trademarks. This is an independent project, built from community protocol notes and testing on real hardware.

## ⚠️ Safety

**This software controls real charge and discharge currents, and the charger does very little checking of what it's sent.** In testing:

- Over **Bluetooth**, out-of-range values were stored exactly as sent, including a 5,000 mA charge current and a 4.2 V charge stop on a NiMH program.
- Over **USB**, an out-of-range value made the charger replace the whole slot program with **Li-ion defaults (4.2 V)** while still acknowledging the write.

The app's limit checks are the main protection against bad values, and they can have bugs. Batteries can overheat, vent or catch fire.

- Stay near the charger while it runs, and don't leave cells unattended.
- Check the cell type and settings yourself before every start.
- Use this at your own risk. The software comes with no warranty (see [LICENSE](LICENSE)).

## Features

- **Live view** of all four slots: voltage, current, capacity, energy, temperature, internal resistance and elapsed time, with charts.
- **Program editor** with limits for each battery type, C-rate helpers and presets. Values past the charger's limits are blocked, and risky values inside them get a warning.
- **Check before start:** over USB, every field is read back and compared before a slot can start.
- **Test history:** per-phase reports, data coverage, marked connection gaps and CSV export.
- **Cell library** with capacity and resistance trends, plus **pack matching**.
- **Stop controls:** Stop all slots and per-slot stop. Each stopped test records what stopped it: the button, the safety stop or no command from this app, which points to the charger or something else.
- **Mac notifications** for finished runs, faults and lost connections.

## Tested with

| | |
|---|---|
| Charger | SkyRC MC3000, firmware 1.27, hardware 2.2 |
| Mac | macOS 27 on Apple silicon |
| Cells | NiMH AA cells, mostly set up as generic NiMH |

**Tested on that charger:** status over USB and Bluetooth, program write and read-back, start, per-slot and all-slot stop, Charge, Discharge, Refresh, Break-in and Cycle starting correctly, time, capacity and temperature cutoffs, and -dV and voltage endings on NiMH.

**Not tested yet:**

- Li-ion, LiFePO4, NiCd or anything except NiMH and Eneloop
- other firmware versions
- removing a cell mid-run, and most fault types
- full Cycle runs and Refresh with different settings

**The charger must be set to °C.** Programs are locked on a charger set to °F, because that setting hasn't been tested.

**MC5000 and other models aren't supported.** The app re-reads the charger's machine ID before each write or start and refuses unless it matches the MC3000's. NiZn, RAM, LTO and Na-ion can be monitored but not programmed.

## How the connections work

The charger's USB port stopped answering while Bluetooth was connected, so the app uses one at a time.

| | USB | Bluetooth |
|---|---|---|
| Live data | More detail: 0.1 mAh, 0.1 °C, charger-measured energy | Basic |
| Read a program back | Yes | No |
| Start one slot | No, starts every loaded slot | Yes |
| Stop one slot | No, stops every slot | Yes |
| Stop all | Yes, about 0.1 s | Yes, under 1 s |

With both available, the app logs over USB and switches to Bluetooth to start or stop one slot, which leaves a gap of about 5–8 seconds, marked in the log.

- **Pairing:** the app never pairs by itself. Choose your charger when it offers the ones nearby. Right-click the connection status to forget it. The charger's Bluetooth has no authentication of its own, so anyone in range with similar tools could still command it.
- **Same charger check:** before a Bluetooth start, the app compares each slot over USB and Bluetooth, and refuses if they look like different chargers.
- **Bluetooth only:** programs can't be read back, so the Start button says so. The app watches the first readings and stops the slot if its type or mode is wrong, or a limit is passed.
- **USB only:** starting launches every loaded slot. The app shows what else would start, and refuses if another slot's stored program looks unsafe. You can't stop just one slot.

## Build and run

Needs macOS 26 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/bucknova/MCX-Control.git
```

```bash
cd MCX-Control && ./build-app.sh
```

```bash
open "MC-X Control.app"
```

The build is ad-hoc signed and not notarized, so it runs on the Mac that built it. A copy downloaded from elsewhere would trigger a macOS security warning.

Your test data is stored in `~/Library/Application Support/MC-X Control/`.

### Checks

The protocol, limit and run-tracking logic has a standalone test program, using frames captured from a real charger:

```bash
swift run MCXCoreCheck
```

### Replay mode

To work on the interface without a charger, replay a recorded USB log. Replay never opens USB or Bluetooth. The CSV needs a final column of raw frame bytes in hex.

```bash
open -n --env MCX_REPLAY=/path/to/log.csv --env MCX_DB=/tmp/demo.sqlite "MC-X Control.app"
```

## Layout

| Path | Contents |
|---|---|
| `Sources/MCXCore` | Protocol, limits, run tracking, analysis and storage, with no UI |
| `Sources/MCXControl` | The SwiftUI app and the USB and Bluetooth links |
| `Sources/MCXCoreCheck` | Standalone checks |
| `docs/PROTOCOL.md` | What's known about the charger's protocol |

## Contributing

Issues and pull requests are welcome, especially test results from other firmware versions and battery types. Please never include anything from SkyRC's software in the repo. Protocol facts are fine.

## Credits

The protocol knowledge here comes from the work of others, and no code from these projects was copied:

- [skyrc-ble](https://github.com/kroimon/skyrc-ble) by Stefan Rado: Bluetooth protocol analysis
- [mc3000-mcp](https://github.com/nietonchique/mc3000-mcp): Bluetooth and firmware notes
- [kolinger/skyrc-mc3000](https://github.com/kolinger/skyrc-mc3000): USB slot program format
- [openMC3000](https://github.com/GlassOnTin/openmc3000): USB protocol notes
- [GNU DataExplorer](https://www.nongnu.org/dataexplorer/): original USB framing, as cited by those projects

Limit ranges were checked against values in SkyRC's own Android app.

## License

[MIT](LICENSE)
