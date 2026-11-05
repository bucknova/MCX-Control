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
    enum Outcome: Equatable { case verified, mismatch, writeFailed, unverifiedBluetooth, notAllowed(String) }
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
    private(set) var lastReadingTime = Date()
    private(set) var bluetoothDenied = false
    private(set) var candidates: [BluetoothCandidate] = []
    private(set) var replayFinished = false
    /// Each link reports its own charger, and forgets it as soon as that link goes away.
    private(set) var usbIdentity: Wire.Version?
    private(set) var bluetoothIdentity: Wire.Version?

    @ObservationIgnored var onReading: ((SlotReading, Date) -> Void)?
    @ObservationIgnored var onSafetyStop: ((Int, String) -> Void)?

    @ObservationIgnored private let usb = USBLink()
    @ObservationIgnored private let ble = BluetoothLink()
    /// Polling and every control action take turns, so one can't pull a connection out from under another.
    @ObservationIgnored private let control = AsyncLock()
    @ObservationIgnored private var holds = 0
    @ObservationIgnored private var usbMisses = 0
    @ObservationIgnored private var usbQuietUntil = Date.distantPast
    @ObservationIgnored private var strikes = [0, 0, 0, 0]
    @ObservationIgnored private var safetyStopRunning = Set<Int>()
    @ObservationIgnored private var guards: [Int: (program: Program, started: Date)] = [:]

    var identity: Wire.Version? { connection == .bluetooth ? (bluetoothIdentity ?? usbIdentity) : (usbIdentity ?? bluetoothIdentity) }
    var firmware: String? { identity?.firmware }
    var isReplay: Bool { connection == .replay }
    var isPaired: Bool { ble.pairedID != nil }
    private var usbPreferred: Bool { usb.present && Date() >= usbQuietUntil }

    /// Why this charger can't be written to or started right now, if anything.
    static func blockReason(_ v: Wire.Version?) -> String? {
        guard let v else { return "The charger hasn't identified itself yet. Nothing was sent." }
        guard v.isMC3000 else { return "This charger hasn't identified itself as an MC3000, and other models use different commands. Nothing was sent." }
        if v.isFahrenheit == true { return "The charger is set to °F. Temperature cutoffs are only tested in °C, so change it to °C on the charger first. Nothing was sent." }
        return nil
    }

    func start(replayCSV: String?) {
        if let replayCSV {
            // A replay never touches the hardware, even if its file can't be read.
            var frames: [[UInt8]] = []
            for line in ((try? String(contentsOfFile: replayCSV, encoding: .utf8)) ?? "").split(separator: "\n").dropFirst() {
                guard let raw = line.split(separator: ",").last else { continue }
                var f = raw.split(separator: " ").compactMap { UInt8($0, radix: 16) }
                f += [UInt8](repeating: 0, count: max(0, 64 - f.count)); f[63] = Wire.checksum(f[0..<63]); frames.append(f)
            }
            connection = .replay
            usbIdentity = Wire.Version(firmware: "1.27", hardware: "2.2", machineID: Wire.Version.mc3000ID)
            Task { await replayLoop(frames) }
            return
        }
        usb.onChange = { [weak self] in self?.usbIdentity = nil; self?.usbQuietUntil = .distantPast; self?.usbMisses = 0 }
        ble.onDisconnect = { [weak self] in self?.bluetoothIdentity = nil }
        ble.onCandidates = { [weak self] in self?.candidates = $0 }
        usb.start(); ble.start()
        Task { await pollLoop() }
    }

    func pair(with id: UUID) { ble.pair(with: id) }
    func forgetPairing() { Task { await hold { await ble.forgetPairing() } } }

    private func replayLoop(_ frames: [[UInt8]]) async {
        var i = 0
        while i < frames.count {
            for _ in 0..<4 where i < frames.count {
                if let r = Wire.parseUSBLive(frames[i]) { publish(r) }
                i += 1
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
            if holds == 0 {
                await control.acquire()
                await pollOnce()
                control.release()
            }
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
    private func refreshUSBIdentity() async {
        usbIdentity = await usb.request(Wire.usbSystem, timeout: 1, match: { $0[0] == 0x5A }).flatMap(Wire.parseUSBVersion)
    }
    private func refreshBluetoothIdentity() async {
        guard var v = await ble.request(Wire.bleVersion(), timeout: 1.5, match: { $0.count == 20 && $0[1] == 0x57 }).flatMap(Wire.parseBluetoothVersion) else { bluetoothIdentity = nil; return }
        v.isFahrenheit = await ble.request(Wire.bleSettings(), timeout: 1.5, match: { $0.count == 20 && $0[1] == 0x61 }).flatMap(Wire.parseBluetoothIsFahrenheit)
        bluetoothIdentity = v
    }
    private func pollOnce() async {
        if usbPreferred {
            if ble.isConnected { await ble.disconnect() }
            var any = false
            for s in 0..<4 where holds == 0 { if let r = await usbLive(s) { publish(r); any = true } }
            if any {
                usbMisses = 0; connection = .usb
                if usbIdentity == nil { await refreshUSBIdentity() }
                return
            }
            usbMisses += 1
            if usbMisses < 8 { return } // USB pauses for a few seconds after a start or a Bluetooth disconnect.
            usbQuietUntil = Date().addingTimeInterval(60) // Plugged in but silent: log over Bluetooth, and try USB again in a minute.
            usbMisses = 0
        }
        if !ble.isConnected {
            connection = .none
            guard await ble.connect(timeout: 6), holds == 0 else { return }
        }
        connection = .bluetooth
        for s in 0..<4 where holds == 0 { if let r = await bleStatus(s) { publish(r) } }
        if bluetoothIdentity == nil, holds == 0 { await refreshBluetoothIdentity() }
    }

    // MARK: Connection control
    private func hold<T>(_ body: () async -> T) async -> T {
        holds += 1
        await control.acquire()
        defer { control.release(); holds -= 1 }
        return await body()
    }

    private func useBluetooth<T>(_ body: () async -> T) async -> T? {
        if !ble.isConnected { connection = .switching }
        guard await ble.connect(timeout: 8) else { connection = usb.present ? .usb : .none; return nil }
        let result = await body()
        if usbPreferred { await ble.disconnect(); await waitForUSB() }
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
    /// Immediate: the command goes out first, without waiting its turn, and the turn is only for confirming it worked.
    @discardableResult func stopAll() async -> Bool {
        if ble.isConnected { ble.sendNow(Wire.bleStopAll) } else if usb.present { usb.send(Wire.usbStopAll) }
        return await hold {
            var ok = false
            if !ble.isConnected && usb.present {
                usb.send(Wire.usbStopAll)
                ok = await verifyIdle(usingUSB: true)
            }
            if !ok, await ble.connect(timeout: 6) {
                _ = await ble.request(Wire.bleStopAll, timeout: 2) { $0.count == 20 && $0[1] == 0xFE }
                ok = await verifyIdle(usingUSB: false, within: 2)
                if !ok { // Fall back to the slot-by-slot stop, which is known to work on any firmware.
                    for s in 0..<4 { _ = await ble.request(Wire.bleStop(slot: s), timeout: 2) { Wire.isAck($0, op: 0xFE, slot: s) } }
                    ok = await verifyIdle(usingUSB: false)
                }
                if usbPreferred { await awayFromBluetooth() }
            }
            if ok { guards.removeAll() } // If a slot might still be running, its limits stay in force.
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
            guard let r else { return .needsBluetooth }
            if r { guards[s] = nil } // If it didn't stop, its limits stay in force.
            return r ? .stopped : .failed
        }
    }

    // MARK: Write and check
    /// Writes the program to each slot and reads back every field where it can. Nothing starts here.
    func writeAndCheck(_ p: Program, slots: [Int]) async -> [SlotCheck] {
        guard p.isEncodable else { return slots.map { SlotCheck(slot: $0, sent: p, onCharger: nil, outcome: .notAllowed("A value in this program is out of range. Nothing was sent.")) } }
        return await hold {
            let viaUSB = usbPreferred
            if viaUSB {
                await awayFromBluetooth()
                await refreshUSBIdentity()
                if let reason = Self.blockReason(usbIdentity) { return slots.map { SlotCheck(slot: $0, sent: p, onCharger: nil, outcome: .notAllowed(reason)) } }
            } else {
                guard await ble.connect(timeout: 8) else { return slots.map { SlotCheck(slot: $0, sent: p, onCharger: nil, outcome: .writeFailed) } }
                connection = .bluetooth
                await refreshBluetoothIdentity()
                if let reason = Self.blockReason(bluetoothIdentity) { return slots.map { SlotCheck(slot: $0, sent: p, onCharger: nil, outcome: .notAllowed(reason)) } }
            }
            var out: [SlotCheck] = []
            for s in slots {
                // Writing to a running slot changes it live, so this needs a fresh reading, not the last known one.
                guard let now = viaUSB ? await usbLive(s, timeout: 1) : await bleStatus(s), !now.status.isActive else {
                    out.append(SlotCheck(slot: s, sent: p, onCharger: nil, outcome: .writeFailed)); continue
                }
                publish(now)
                if viaUSB {
                    let acked = await usb.request(p.usbFrame(slot: s), timeout: 2) { $0[0] == 0xF0 } != nil
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let reply = await usb.request(Wire.usbProgram(slot: s), timeout: 1.5) { $0.count == 64 && $0[0] == 0x5F && Int($0[1]) == s }
                    let got = reply.flatMap(Program.init(usbReply:))
                    out.append(SlotCheck(slot: s, sent: p, onCharger: got, outcome: !acked || got == nil ? .writeFailed : got == p ? .verified : .mismatch))
                } else {
                    var ok = await ble.writeProgram(p.bluetoothFrame(slot: s), slot: s)
                    if !ok { ok = await ble.writeProgram(p.bluetoothFrame(slot: s), slot: s) }
                    out.append(SlotCheck(slot: s, sent: p, onCharger: nil, outcome: ok ? .unverifiedBluetooth : .writeFailed))
                }
            }
            return out.sorted { $0.slot < $1.slot }
        }
    }

    enum StartOutcome: Equatable { case started, failed(String), needsGlobalConfirmation([OtherSlotOnStart]) }
    private enum BluetoothStart { case done(allConfirmed: Bool), refused(String) }

    /// Starts only these slots, over Bluetooth. Without Bluetooth, USB can only start every loaded slot, so that needs a separate confirmation.
    func start(checks: [SlotCheck]) async -> StartOutcome {
        await hold {
            let ready = checks.filter(\.canStart)
            guard !ready.isEmpty else { return .failed("No slot passed its check.") }
            let usbView = readings
            let result: BluetoothStart? = await useBluetooth {
                await refreshBluetoothIdentity()
                if let reason = Self.blockReason(bluetoothIdentity) { return .refused(reason) }
                // A USB read-back only proves something if Bluetooth reaches the same charger.
                for s in 0..<4 {
                    guard let was = usbView[s], was.source == .usb, let now = await bleStatus(s) else { continue }
                    if Limits.looksLikeDifferentCharger(usb: was, bluetooth: now) {
                        return .refused("Slot \(s + 1) reads differently over Bluetooth and USB, so they may be connected to different chargers. Nothing was started.")
                    }
                    publish(now)
                }
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
                return .done(allConfirmed: all)
            }
            switch result {
            case .done(true): return .started
            case .done(false): return .failed("The charger didn't confirm every start. Check the slots on the Live screen.")
            case .refused(let reason): return .failed(reason)
            case .none:
                guard usb.present else { return .failed("Couldn't reach the charger over Bluetooth or USB.") }
                await refreshUSBIdentity()
                if let reason = Self.blockReason(usbIdentity) { return .failed(reason) }
                return .needsGlobalConfirmation(await otherLoadedSlots(excluding: ready.map(\.slot)))
            }
        }
    }
    /// What else USB's start-everything command would launch, from fresh readings.
    private func otherLoadedSlots(excluding: [Int]) async -> [OtherSlotOnStart] {
        var o: [OtherSlotOnStart] = []
        for s in 0..<4 where !excluding.contains(s) {
            guard let r = await usbLive(s, timeout: 1) else { o.append(OtherSlotOnStart(slot: s, program: nil, problem: "Couldn't read this slot.")); continue }
            guard r.hasCell, !r.status.isActive else { continue }
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
    /// Refuses if any other loaded slot's stored program looks wrong for it, and asks again if anything changed since the confirmation was shown.
    func startAllOverUSB(checks: [SlotCheck], others: [OtherSlotOnStart]) async -> StartOutcome {
        await hold {
            await refreshUSBIdentity()
            if let reason = Self.blockReason(usbIdentity) { return .failed(reason) }
            let now = await otherLoadedSlots(excluding: checks.filter(\.canStart).map(\.slot))
            guard now == others else { return .needsGlobalConfirmation(now) }
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
        // On a °F charger the reading's unit is unconfirmed, so the app's own temperature check would misfire. The charger's cutoff still applies.
        var problem = Limits.runtimeProblem(r, program: g?.program, checkTemperature: identity?.isFahrenheit != true)
        // Bluetooth can't read a program back, so the first readings after a start are the check: wrong type or mode gets stopped.
        if let g, Date().timeIntervalSince(g.started) > 5, r.status.isActive, r.rawType != g.program.type.rawValue || r.rawMode != g.program.mode.rawValue {
            problem = "it started as \(r.type?.name ?? "an unknown type") \(r.mode?.name(for: r.type) ?? ""), not the program that was sent"
        }
        // Once this program has ended, its limits no longer apply to whatever runs in the slot next.
        if let g, Date().timeIntervalSince(g.started) > 15, !r.status.isActive { guards[r.slot] = nil }
        strikes[r.slot] = problem == nil ? 0 : strikes[r.slot] + 1
        guard let problem, strikes[r.slot] >= 2, !safetyStopRunning.contains(r.slot) else { return }
        strikes[r.slot] = 0
        safetyStopRunning.insert(r.slot)
        onSafetyStop?(r.slot, problem)
        Task {
            if await stop(slot: r.slot) != .stopped { await stopAll() }
            safetyStopRunning.remove(r.slot)
        }
    }
}
