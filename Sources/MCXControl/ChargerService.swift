import Foundation
import MCXCore
import Observation

enum Connection: Equatable { case none, usb, bluetooth, switching, replay
    var label: String {
        switch self {
        case .none: "Not connected"
        case .usb: "Logging over USB"
        case .bluetooth: "Logging over Bluetooth"
        case .switching: "Switching connection…"
        case .replay: "Replaying a recorded run"
        }
    }
}

struct SlotCheck: Identifiable, Equatable {
    enum Outcome: Equatable { case verified, mismatch, writeFailed, unverifiedBluetooth, unsupportedCharger }
    let slot: Int
    let sent: Program
    let onCharger: Program?
    let outcome: Outcome
    var id: Int { slot }
    var canStart: Bool { outcome == .verified || outcome == .unverifiedBluetooth }
}

struct OtherSlotOnStart: Identifiable, Equatable { let slot: Int; let program: Program?; let problem: String?; var id: Int { slot } }

/// Owns both connections. USB stops answering while Bluetooth is connected, so only one is ever in use.
@MainActor @Observable final class ChargerService {
    private(set) var connection = Connection.none
    private(set) var readings: [SlotReading?] = [nil, nil, nil, nil]
    private(set) var firmware: String?
    private(set) var hardware: String?
    /// nil until the charger has identified itself.
    private(set) var isSupportedModel: Bool?
    private(set) var lastReadingTime = Date()
    private(set) var bluetoothDenied = false
    var preferBluetooth = UserDefaults.standard.bool(forKey: "preferBluetooth") { didSet { UserDefaults.standard.set(preferBluetooth, forKey: "preferBluetooth") } }

    @ObservationIgnored var onReading: ((SlotReading, Date) -> Void)?
    @ObservationIgnored var onSafetyStop: ((Int, String) -> Void)?

    @ObservationIgnored private let usb = USBLink()
    @ObservationIgnored private let ble = BluetoothLink()
    @ObservationIgnored private var holds = 0
    @ObservationIgnored private var usbMisses = 0
    @ObservationIgnored private var strikes = [0, 0, 0, 0]
    @ObservationIgnored private var guards: [Int: (program: Program, started: Date)] = [:]
    @ObservationIgnored private var replay: [[UInt8]] = []
    @ObservationIgnored private var replayIndex = 0
    var usbAvailable: Bool { usb.present }
    var isReplay: Bool { connection == .replay }
    private(set) var replayFinished = false

    func start(replayCSV: String?) {
        if let replayCSV, let t = try? String(contentsOfFile: replayCSV, encoding: .utf8) {
            for line in t.split(separator: "\n").dropFirst() {
                guard let raw = line.split(separator: ",").last else { continue }
                var f = raw.split(separator: " ").compactMap { UInt8($0, radix: 16) }
                f += [UInt8](repeating: 0, count: max(0, 64 - f.count)); f[63] = Wire.checksum(f[0..<63]); replay.append(f)
            }
            connection = .replay; firmware = "1.27"; hardware = "2.2"
            Task { await replayLoop() }
            return
        }
        usb.start(); ble.start()
        Task { await pollLoop() }
    }

    private func replayLoop() async {
        while replayIndex < replay.count {
            for _ in 0..<4 where replayIndex < replay.count {
                if let r = Wire.parseUSBLive(replay[replayIndex]) { publish(r) }
                replayIndex += 1
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        replayFinished = true
    }

    private func publish(_ r: SlotReading) {
        readings[r.slot] = r; lastReadingTime = Date()
        onReading?(r, Date()); runtimeGuard(r)
    }

    // MARK: Polling
    private func pollLoop() async {
        while !Task.isCancelled {
            let t0 = Date()
            if holds == 0 { await pollOnce() }
            bluetoothDenied = ble.unauthorized
            let wait = max(0.1, 1.0 - Date().timeIntervalSince(t0))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
        }
    }
    private func usbLive(_ s: Int, timeout: Double = 0.5) async -> SlotReading? {
        await usb.request(Wire.usbLive(slot: s), timeout: timeout) { $0.count == 64 && $0[0] == 0x55 && Int($0[1]) == s }.flatMap(Wire.parseUSBLive)
    }
    private func bleStatus(_ s: Int, timeout: Double = 1.5) async -> SlotReading? {
        await ble.request(Wire.bleStatus(slot: s), timeout: timeout) { $0.count == 20 && $0[1] == 0x55 && Int($0[2]) == s }.flatMap(Wire.parseBluetoothStatus)
    }
    private func pollOnce() async {
        if usb.present && !preferBluetooth {
            if ble.isConnected { await ble.disconnect() }
            var any = false
            for s in 0..<4 where holds == 0 { if let r = await usbLive(s) { publish(r); any = true } }
            if any {
                usbMisses = 0; connection = .usb
                if firmware == nil, let v = await usb.request(Wire.usbSystem, timeout: 1, match: { $0[0] == 0x5A }).flatMap(Wire.parseUSBVersion) { firmware = v.firmware; hardware = v.hardware; isSupportedModel = v.isMC3000 }
                return
            }
            usbMisses += 1
            if usbMisses < 8 { return } // USB pauses for a few seconds after a start or a Bluetooth disconnect.
        }
        if !ble.isConnected {
            connection = .none
            guard await ble.connect(timeout: 6), holds == 0 else { return }
        }
        connection = .bluetooth; usbMisses = 0
        for s in 0..<4 where holds == 0 { if let r = await bleStatus(s) { publish(r) } }
        if firmware == nil, let v = await ble.request(Wire.bleVersion(), timeout: 1.5, match: { $0.count == 20 && $0[1] == 0x57 }).flatMap(Wire.parseBluetoothVersion) { firmware = v.firmware; hardware = v.hardware; isSupportedModel = v.isMC3000 }
    }

    // MARK: Connection control
    private func hold<T>(_ body: () async -> T) async -> T { holds += 1; defer { holds -= 1 }; return await body() }

    private func useBluetooth<T>(_ body: () async -> T) async -> T? {
        let wasConnected = ble.isConnected
        if !wasConnected { connection = .switching }
        guard await ble.connect(timeout: 8) else { connection = usb.present ? .usb : .none; return nil }
        let result = await body()
        if usb.present && !preferBluetooth { await ble.disconnect(); await waitForUSB() }
        return result
    }
    private func waitForUSB() async {
        let end = Date().addingTimeInterval(9)
        while Date() < end {
            if let r = await usbLive(0, timeout: 0.6) { publish(r); connection = .usb; return }
        }
    }
    private func awayFromBluetooth() async {
        guard ble.isConnected, usb.present else { return }
        connection = .switching; await ble.disconnect(); await waitForUSB()
    }

    // MARK: Stop
    /// Immediate. Over USB this is one command that stops everything; over Bluetooth, one per slot.
    @discardableResult func stopAll() async -> Bool {
        await hold {
            var ok = false
            if connection == .usb || (!ble.isConnected && usb.present) {
                usb.send(Wire.usbStopAll); usb.send(Wire.usbStopAll)
                ok = await verifyIdle(usingUSB: true)
            }
            if !ok, await ble.connect(timeout: 6) {
                _ = await ble.request(Wire.bleStopAll, timeout: 2) { $0.count == 20 && $0[1] == 0xFE }
                ok = await verifyIdle(usingUSB: false, within: 2)
                if !ok { // Fall back to the slot-by-slot stop, which is known to work on any firmware.
                    for s in 0..<4 { _ = await ble.request(Wire.bleStop(slot: s), timeout: 2) { Wire.isAck($0, op: 0xFE, slot: s) } }
                    ok = await verifyIdle(usingUSB: false)
                }
                if usb.present && !preferBluetooth { await awayFromBluetooth() }
            }
            guards.removeAll()
            return ok
        }
    }
    private func verifyIdle(usingUSB: Bool, within: Double = 5) async -> Bool {
        let end = Date().addingTimeInterval(within)
        while Date() < end {
            var rs: [SlotReading] = []
            for s in 0..<4 { if let r = usingUSB ? await usbLive(s) : await bleStatus(s) { publish(r); rs.append(r) } }
            if rs.count == 4, rs.allSatisfy({ !$0.status.isActive && $0.milliamps == 0 }) { return true }
        }
        return false
    }

    enum StopResult { case stopped, failed, needsBluetooth }
    /// Single-slot stop only exists over Bluetooth.
    func stop(slot s: Int) async -> StopResult {
        await hold {
            let r: Bool? = await useBluetooth {
                for _ in 0..<3 {
                    _ = await ble.request(Wire.bleStop(slot: s), timeout: 2.5) { Wire.isAck($0, op: 0xFE, slot: s) }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if let st = await bleStatus(s) { publish(st); if !st.status.isActive && st.milliamps == 0 { return true } }
                }
                return false
            }
            guards[s] = nil
            guard let r else { return .needsBluetooth }
            return r ? .stopped : .failed
        }
    }

    // MARK: Write and check
    /// Writes the program to each slot and reads back every field where it can. Nothing starts here.
    func writeAndCheck(_ p: Program, slots: [Int]) async -> [SlotCheck] {
        // Only MC3000 frames exist so far, so nothing is written until the charger has identified itself as one.
        guard isSupportedModel == true else { return slots.map { SlotCheck(slot: $0, sent: p, onCharger: nil, outcome: .unsupportedCharger) } }
        return await hold {
            var out: [SlotCheck] = []
            let idle = slots.filter { !(readings[$0]?.status.isActive ?? false) }
            for s in slots where !idle.contains(s) { out.append(SlotCheck(slot: s, sent: p, onCharger: nil, outcome: .writeFailed)) }
            if usb.present && !preferBluetooth {
                await awayFromBluetooth()
                for s in idle {
                    let acked = await usb.request(p.usbFrame(slot: s), timeout: 2) { $0[0] == 0xF0 } != nil
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let reply = await usb.request(Wire.usbProgram(slot: s), timeout: 1.5) { $0.count == 64 && $0[0] == 0x5F && Int($0[1]) == s }
                    let got = reply.flatMap(Program.init(usbReply:))
                    out.append(SlotCheck(slot: s, sent: p, onCharger: got, outcome: !acked || got == nil ? .writeFailed : got == p ? .verified : .mismatch))
                }
            } else if await ble.connect(timeout: 8) {
                connection = .bluetooth
                for s in idle {
                    var ok = await ble.writeProgram(p.bluetoothFrame(slot: s), slot: s)
                    if !ok { ok = await ble.writeProgram(p.bluetoothFrame(slot: s), slot: s) } // A write has been seen to vanish, so one retry.
                    out.append(SlotCheck(slot: s, sent: p, onCharger: nil, outcome: ok ? .unverifiedBluetooth : .writeFailed))
                }
            } else {
                out += idle.map { SlotCheck(slot: $0, sent: p, onCharger: nil, outcome: .writeFailed) }
            }
            return out.sorted { $0.slot < $1.slot }
        }
    }

    enum StartOutcome: Equatable { case started, failed(String), needsGlobalConfirmation([OtherSlotOnStart]) }

    /// Starts only these slots, over Bluetooth. Without Bluetooth, USB can only start every loaded slot, so that needs a separate confirmation.
    func start(checks: [SlotCheck]) async -> StartOutcome {
        guard isSupportedModel == true else { return .failed("This charger hasn't identified itself as an MC3000, so the app won't start it.") }
        return await hold {
            let ready = checks.filter(\.canStart)
            guard !ready.isEmpty else { return .failed("No slot passed its check.") }
            let result: Bool? = await useBluetooth {
                var all = true
                for c in ready {
                    // A slot showing Done or a cutoff ignores start until it has been cleared with a stop.
                    if let r = readings[c.slot], r.status.isDone || r.status.isFault {
                        _ = await ble.request(Wire.bleStop(slot: c.slot), timeout: 2.5) { Wire.isAck($0, op: 0xFE, slot: c.slot) }
                        try? await Task.sleep(nanoseconds: 400_000_000)
                    }
                    let acked = await ble.request(Wire.bleStart(slot: c.slot), timeout: 3) { Wire.isAck($0, op: 0x05, slot: c.slot) } != nil
                    if acked { guards[c.slot] = (c.sent, Date()) } else { all = false }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                return all
            }
            switch result {
            case .some(true): return .started
            case .some(false): return .failed("The charger didn't confirm every start. Check the slots on the Live screen.")
            case .none:
                guard usb.present else { return .failed("Couldn't reach the charger over Bluetooth or USB.") }
                return .needsGlobalConfirmation(await otherLoadedSlots(excluding: ready.map(\.slot)))
            }
        }
    }
    /// What else USB's start-everything command would launch.
    private func otherLoadedSlots(excluding: [Int]) async -> [OtherSlotOnStart] {
        var o: [OtherSlotOnStart] = []
        for s in 0..<4 where !excluding.contains(s) {
            guard let r = readings[s], r.hasCell, !r.status.isActive else { continue }
            let reply = await usb.request(Wire.usbProgram(slot: s), timeout: 1.5) { $0.count == 64 && $0[0] == 0x5F && Int($0[1]) == s }
            let prog = reply.flatMap(Program.init(usbReply:))
            var problem: String?
            if let prog {
                let rated = max(prog.capacityLimit, 1000)
                problem = Limits.validate(prog, ratedCapacity: rated).first { $0.severity == .blocker }?.message
                if prog.temperatureCutoff < 25 { problem = "Its \(prog.temperatureCutoff) °C temperature cutoff would stop it right away." }
            } else { problem = "Couldn't read its program." }
            o.append(OtherSlotOnStart(slot: s, program: prog, problem: problem))
        }
        return o
    }
    /// Refuses if any other loaded slot's stored program looks wrong for it.
    func startAllOverUSB(checks: [SlotCheck], others: [OtherSlotOnStart]) async -> StartOutcome {
        guard isSupportedModel == true else { return .failed("This charger hasn't identified itself as an MC3000, so the app won't start it.") }
        return await hold {
            guard others.allSatisfy({ $0.problem == nil }) else { return .failed("Another loaded slot has a program that isn't safe to start. Fix or empty it first.") }
            // USB can only clear a Done slot with its stop-everything command, which is safe only when nothing is running.
            if readings.contains(where: { $0?.status.isDone == true || $0?.status.isFault == true }) {
                guard !readings.contains(where: { $0?.status.isActive == true }) else { return .failed("A finished slot has to be cleared first, and USB can't do that while another slot is running. Stop that slot or use Bluetooth.") }
                usb.send(Wire.usbStopAll)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            guard usb.send(Wire.usbStartAll) else { return .failed("USB didn't accept the start.") }
            for c in checks where c.canStart { guards[c.slot] = (c.sent, Date()) }
            for o in others { if let p = o.program { guards[o.slot] = (p, Date()) } }
            return .started
        }
    }

    // MARK: Runtime protection
    private func runtimeGuard(_ r: SlotReading) {
        let g = guards[r.slot]
        var problem = Limits.runtimeProblem(r, program: g?.program)
        // Bluetooth can't read a program back, so the first readings after a start are the check: wrong type or mode gets stopped.
        if let g, Date().timeIntervalSince(g.started) > 5, r.status.isActive, r.rawType != g.program.type.rawValue || r.rawMode != g.program.mode.rawValue {
            problem = "it started as \(r.type?.name ?? "an unknown type") \(r.mode?.name(for: r.type) ?? ""), not the program that was sent"
        }
        // Once this program has ended, its limits no longer apply to whatever runs in the slot next.
        if let g, Date().timeIntervalSince(g.started) > 15, !r.status.isActive { guards[r.slot] = nil }
        strikes[r.slot] = problem == nil ? 0 : strikes[r.slot] + 1
        guard let problem, strikes[r.slot] >= 2 else { return }
        strikes[r.slot] = 0
        onSafetyStop?(r.slot, problem)
        Task {
            if await stop(slot: r.slot) != .stopped { await stopAll() }
        }
    }
    func armGuard(slot: Int, program: Program) { guards[slot] = (program, Date()) }
}
