import AppKit
import Foundation
import MCXCore
import Observation
import UserNotifications

enum AppSection: String, CaseIterable, Identifiable { case live = "Live", programs = "Programs", tests = "Tests", cells = "Cells", match = "Pack match"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .live: "waveform.path.ecg"
        case .programs: "slider.horizontal.3"
        case .tests: "list.bullet.rectangle"
        case .cells: "battery.100percent"
        case .match: "square.grid.2x2"
        }
    }
}

@MainActor @Observable final class AppModel {
    let store: Store
    let charger = ChargerService()
    var section = AppSection.live
    var selectedSlot = 3
    var cells: [Cell] = []
    var runs: [RunRecord] = []
    var presets: [NamedProgram] = []
    var slotCell: [Int64?] = [nil, nil, nil, nil]
    var live: [[Sample]] = [[], [], [], []]
    var currentRun: [Int64?] = [nil, nil, nil, nil]
    var banner: String?
    var lostConnection = false
    var draft = Limits.suggested(type: .nimh, mode: .charge, rated: 2450, cRate: 0.5)
    var draftRated = 2450
    var draftSlots: Set<Int> = []
    var storeError: String?

    @ObservationIgnored private var trackers = [RunTracker(), RunTracker(), RunTracker(), RunTracker()]
    @ObservationIgnored private var slotProgram: [Program?] = [nil, nil, nil, nil]
    @ObservationIgnored private var awake: NSObjectProtocol?
    @ObservationIgnored private var replayNoticeShown = false
    @ObservationIgnored private let canNotify = Bundle.main.bundleIdentifier != nil

    var anyActive: Bool { charger.readings.contains { $0?.status.isActive == true } }
    var anyRecording: Bool { currentRun.contains { $0 != nil } }

    init() {
        let env = ProcessInfo.processInfo.environment
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MC-X Control")
        store = try! Store(path: env["MCX_DB"] ?? dir.appendingPathComponent("monitor.sqlite").path)
        reload()
        for s in 0..<4 {
            if let r = store.openRun(slot: s) {
                let samples = store.samples(run: r.id)
                currentRun[s] = r.id; live[s] = samples; slotCell[s] = r.cellID; slotProgram[s] = r.program
                trackers[s] = RunTracker(resuming: .init(type: r.rawType, mode: r.rawMode, lastElapsed: samples.last?.elapsed ?? 0))
            } else if let last = runs.first(where: { $0.slot == s }) {
                live[s] = store.samples(run: last.id)
            }
        }
        charger.onReading = { [weak self] r, t in self?.handle(r, at: t) }
        charger.onSafetyStop = { [weak self] slot, why in self?.alert("Slot \(slot + 1) stopped by the app", "Its \(why).") }
        if canNotify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        charger.start(replayCSV: env["MCX_REPLAY"])
        Task { await watchConnection() }
    }

    func reload() { cells = store.cells(); runs = store.runs(); presets = store.presets() }
    func cell(_ id: Int64?) -> Cell? { id.flatMap { i in cells.first { $0.id == i } } }

    private func handle(_ r: SlotReading, at t: Date) {
        let s = r.slot
        for e in trackers[s].ingest(r) {
            switch e {
            case .started(let joined):
                currentRun[s] = store.createRun(slot: s, cellID: slotCell[s], type: r.rawType, mode: r.rawMode, program: slotProgram[s], started: t, joinedAt: joined ? r.elapsed : 0)
                live[s] = []; runs = store.runs(); updateAwake()
            case .resumed: break
            case .sample:
                guard let id = currentRun[s] else { continue }
                let x = Sample(reading: r, at: t)
                store.append(run: id, x); live[s].append(x)
            case .ended(let status, let reason):
                guard let id = currentRun[s] else { continue }
                let a = Analysis.analyze(live[s])
                store.finish(run: id, status: status.raw, reason: reason.rawValue, at: t, analysis: a)
                currentRun[s] = nil; slotProgram[s] = nil; runs = store.runs(); updateAwake()
                let who = cell(slotCell[s])?.label ?? "Slot \(s + 1)"
                let cap = a.dischargeCapacity ?? (a.chargeCapacity > 0 ? a.chargeCapacity : nil)
                let capText = cap.map { String(format: "%.0f mAh", $0) } ?? "no capacity recorded"
                switch reason {
                case .finished: alert("Test finished · Slot \(s + 1)", "\(who): \(capText). Data coverage \(Int(a.coverage * 100))%.")
                case .limit: alert("Limit reached · Slot \(s + 1)", "\(status.label). \(who): \(capText).")
                case .fault: alert("Charger stopped · Slot \(s + 1)", "\(status.label). \(who) stopped at \(capText). Check the cell before using it again.")
                case .stopped: break
                }
            }
        }
    }

    private func updateAwake() {
        if anyRecording, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording charger runs")
        } else if !anyRecording, let a = awake { ProcessInfo.processInfo.endActivity(a); awake = nil }
    }

    private func watchConnection() async {
        while true {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if charger.isReplay {
                if charger.replayFinished, !replayNoticeShown { replayNoticeShown = true; banner = "Replay finished. This recording ends here, so its runs have no ending. Nothing was sent to the charger." }
                continue
            }
            let silent = Date().timeIntervalSince(charger.lastReadingTime) > 30
            if silent && anyRecording && !lostConnection {
                lostConnection = true
                alert("Connection lost", "Tests are still running on the charger, but they aren't being recorded. Reconnecting automatically; the gap will be marked.")
            } else if !silent && lostConnection { lostConnection = false; banner = nil }
        }
    }

    func alert(_ title: String, _ body: String) {
        banner = "\(title): \(body)"
        guard canNotify else { return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func stopAll() { Task { let ok = await charger.stopAll(); if !ok { alert("Stop not confirmed", "Stop the charger with its buttons.") } } }
    func stop(slot: Int) {
        Task {
            switch await charger.stop(slot: slot) {
            case .stopped: break
            case .needsBluetooth: banner = "Stopping one slot needs Bluetooth, which can't be reached. Use Stop all slots, or the charger's buttons."
            case .failed: alert("Stop not confirmed · Slot \(slot + 1)", "Stop it with the charger's buttons.")
            }
        }
    }
    func started(checks: [SlotCheck]) { for c in checks where c.canStart { slotProgram[c.slot] = c.sent } }

    func analysis(of r: RunRecord) -> (samples: [Sample], analysis: RunAnalysis) {
        let s = r.id == currentRun[r.slot] ? live[r.slot] : store.samples(run: r.id)
        return (s, Analysis.analyze(s))
    }
    func assign(run: RunRecord, cell: Int64?) { store.assign(run: run.id, cell: cell); runs = store.runs() }
    func delete(run: RunRecord) { store.delete(run: run.id); runs = store.runs() }

    /// A cell's latest discharge test, for the library and pack matching.
    func latest(for c: Cell) -> RunRecord? { store.runs(cell: c.id).last { ($0.dischargeCapacity ?? 0) > 0 && ($0.mode?.discharges ?? false) } }
}
