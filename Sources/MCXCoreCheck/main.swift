// Standalone checks for the core logic, using frames captured from a real MC3000. Run: swift run MCXCoreCheck
var failures = 0, checks = 0
func expect(_ ok: Bool, line: Int = #line) { checks += 1; if !ok { failures += 1; print("FAILED at line \(line)") } }
struct Missing: Error {}
func need<T>(_ v: T?) throws -> T { guard let v else { throw Missing() }; return v }
import Foundation
import MCXCore
import SQLite3

func bytes(_ s: String) -> [UInt8] { s.split(separator: " ").compactMap { UInt8($0, radix: 16) } }
func pad(_ a: [UInt8], _ n: Int) -> [UInt8] { a + [UInt8](repeating: 0, count: max(0, n - a.count)) }

// Every frame below was captured from a real MC3000, firmware 1.27, hardware 2.2.
struct Decoding {
    func bluetoothStatus() throws {
        let r = try need(Wire.parseBluetoothStatus(bytes("0f 55 03 03 01 00 00 0f 26 05 0c 00 00 00 00 1a 00 2f 80 7a")))
        expect(r.slot == 3); expect(r.type == .nimh); expect(r.mode == .refresh); expect(r.millivolts == 1292)
        expect(r.temperature == 26); expect(r.internalResistance == 47); expect(!r.resistanceIsLive)
    }
    func bluetoothRejectsBadChecksum() { expect(Wire.parseBluetoothStatus(bytes("0f 55 03 03 01 00 00 0f 26 05 0c 00 00 00 00 1a 00 2f 80 7b")) == nil) }
    func version() throws {
        let v = try need(Wire.parseBluetoothVersion(bytes("0f 57 00 31 30 30 30 38 33 01 00 00 00 00 01 1b 16 00 a1 50")))
        expect(v.firmware == "1.27"); expect(v.hardware == "2.2"); expect(v.isMC3000)
        expect(Wire.parseBluetoothIsFahrenheit(bytes("0f 61 00 01 01 01 00 2a f8 00 00 00 00 00 00 00 00 00 00 95")) == false)
        let u = try need(Wire.parseUSBVersion(pad(bytes("5a 00 00 00 00 00 04 01 00 01 00 01 00 00 01 f8 31 30 30 30 38 33 01 00 00 00 00 01 1b 16 00 a1"), 64)))
        expect(u.firmware == "1.27"); expect(u.hardware == "2.2"); expect(u.isMC3000)
        let other = try need(Wire.parseBluetoothVersion(bytes("0f 57 00 39 39 39 39 39 39 01 00 00 00 00 01 1b 16 00 a1 50"))); expect(!other.isMC3000)
    }
    func usbLive() throws {
        var f = pad(bytes("55 00 03 01 00 01 00 50 05 a8 09 8d 00 30 01 06 00 1d 01 15 00 49 0e cd 07 05 e7 4b"), 64)
        f[63] = Wire.checksum(f[0..<63])
        let r = try need(Wire.parseUSBLive(f))
        expect(r.slot == 0); expect(r.status.raw == 1); expect(r.elapsed == 80); expect(r.millivolts == 1448); expect(r.loadedMillivolts == 1511)
        expect(r.milliamps == 2445); expect(r.capacity == 48.7); expect(r.temperature == 26.2); expect(r.internalResistance == 29)
        expect(r.energyMilliwattHours == 73); expect(r.chargerTemperature == 27.7)
    }
}

struct Programs {
    func slot4() -> Program {
        var p = Program(); p.type = .eneloop; p.mode = .charge; p.capacityLimit = 0; p.chargeCurrent = 1000; p.dischargeCurrent = 500
        p.chargeStopMillivolts = 1650; p.dischargeStopMillivolts = 1000; p.chargeEndCurrent = 100; p.dischargeEndCurrent = 500; p.cycles = 1
        p.negativeDeltaMillivolts = 3; p.keepMillivolts = 0; p.temperatureCutoff = 45; p.timeLimitMinutes = 180; return p
    }
    func bluetoothMatchesAcceptedFrame() {
        expect(slot4().bluetoothFrame(slot: 3) == bytes("0f 11 08 06 00 00 00 03 e8 01 f4 06 72 03 e8 00 64 01 f4 00 01 00 03 00 00 00 2d 00 b4 00 00 00 00 00 00 00 00 00 00 af"))
    }
    func usbReplyDecodes() {
        let p = Program(usbReply: pad(bytes("5f 03 00 06 00 00 00 03 e8 01 f4 03 e8 06 72 00 64 01 f4 01 00 00 03 00 00 00 2d 00 b4 00 00 00"), 64))
        expect(p == slot4())
    }
    func usbFrameIsARepackOfTheRead() {
        // Same layout the charger accepted and restored byte for byte.
        let f = slot4().usbFrame(slot: 3)
        expect(Array(f[0..<5]) == [0x0F, 0x20, 0x11, 0x00, 0x03]); expect(f[5] == 6); expect(Array(f[9..<11]) == [0x03, 0xE8])
        expect(Array(f[13..<15]) == [0x03, 0xE8]); expect(Array(f[15..<17]) == [0x06, 0x72]); expect(f[33] == Wire.checksum(f[2..<33])); expect(f[34] == 0xFF)
    }
    func liIonResetIsDetected() {
        // What the charger stored after an out-of-range USB write.
        let reset = Program(usbReply: pad(bytes("5f 02 00 00 00 00 00 03 e8 01 f4 0c e4 10 68 00 64 01 f4 01 00 00 03 03 00 00 2d 00 b4 00 00 00"), 64))
        expect(reset?.type == .liIon); expect(reset?.chargeStopMillivolts == 4200)
        expect(reset != Limits.suggested(type: .nimh, mode: .charge, rated: 2450))
    }
}

struct LimitChecks {
    func blockers(_ p: Program, _ rated: Int = 2450) -> [String] { Limits.validate(p, ratedCapacity: rated).filter { $0.severity == .blocker }.map(\.field) }
    func onecDischargeIsBlocked() {
        var p = Limits.suggested(type: .nimh, mode: .refresh, rated: 2450, cRate: 1); expect(p.dischargeCurrent == 2000); expect(p.chargeCurrent == 2450); expect(blockers(p).isEmpty)
        p.dischargeCurrent = 2450; expect(blockers(p).contains("Discharge current"))
    }
    func unsafeValuesThatBluetoothWouldStoreAreBlocked() {
        var a = Limits.suggested(type: .nimh, mode: .charge, rated: 2450); a.chargeCurrent = 5000; expect(blockers(a).contains("Charge current"))
        var b = Limits.suggested(type: .nimh, mode: .charge, rated: 2450); b.chargeStopMillivolts = 4200; expect(blockers(b).contains("Charge stop"))
        var c = Limits.suggested(type: .liIon, mode: .charge, rated: 3000); c.chargeStopMillivolts = 4350; expect(blockers(c).contains("Charge stop"))
    }
    func officialAppLimits() {
        let v = Limits.voltages(for: .nimh)!
        expect(v.chargeStop == 1470...1800); expect(v.dischargeStop == 500...1100); expect(v.keep == 1300...1450)
        expect(Limits.voltages(for: .eneloop)!.dischargeTypical == 900)
        expect(Limits.suggested(type: .nimh, mode: .charge, rated: 2450).keepMillivolts == 1350)
        expect(blockers(Limits.suggested(type: .li435, mode: .discharge, rated: 3000), 3000).isEmpty)
        var s = Limits.suggested(type: .liIon, mode: .storageOrBreakIn, rated: 3000); expect(s.chargeStopMillivolts == 3800); expect(blockers(s, 3000).isEmpty)
        s.chargeStopMillivolts = 4200; expect(blockers(s, 3000).contains("Charge stop"))
        var k = Limits.suggested(type: .nimh, mode: .charge, rated: 2450); k.keepMillivolts = 1000; expect(blockers(k).contains("Keep voltage"))
        k.keepMillivolts = 0; expect(blockers(k).isEmpty)
        var t = Limits.suggested(type: .nimh, mode: .charge, rated: 2450); t.temperatureCutoff = 70; expect(blockers(t).isEmpty); t.temperatureCutoff = 71; expect(blockers(t).contains("Temperature cutoff"))
        var o = Limits.suggested(type: .nimh, mode: .charge, rated: 2450); o.chargeStopMillivolts = 1800; expect(blockers(o).isEmpty); expect(Limits.validate(o, ratedCapacity: 2450).contains { $0.field == "Charge stop" })
        var d = Limits.suggested(type: .nimh, mode: .discharge, rated: 2450); d.dischargeStopMillivolts = 1300; expect(blockers(d).contains("Discharge stop"))
    }
    func breakInSuggestsSlowCurrentsAndWarns() {
        var b = Limits.suggested(type: .nimh, mode: .storageOrBreakIn, rated: 2450)
        expect(b.chargeCurrent == 245); expect(b.dischargeCurrent == 490); expect(blockers(b).isEmpty)
        expect(!Limits.validate(b, ratedCapacity: 2450).contains { $0.field == "Charge current" })
        b.chargeCurrent = 2450; expect(blockers(b).isEmpty)
        expect(Limits.validate(b, ratedCapacity: 2450).contains { $0.severity == .warning && $0.message.contains("Break-in") })
    }
    func everyEncodedFieldIsChecked() {
        func base() -> Program { Limits.suggested(type: .nimh, mode: .discharge, rated: 2450) }
        var a = base(); a.chargeRestMinutes = -1; expect(!a.isEncodable); expect(blockers(a).contains("Program")); _ = a.bluetoothFrame(slot: 0); _ = a.usbFrame(slot: 0)
        var b = base(); b.cycles = 300; expect(blockers(b).contains("Program")); _ = b.bluetoothFrame(slot: 0)
        var c = base(); c.timeLimitMinutes = -1; expect(!c.isEncodable)
        var d = base(); d.chargeEndCurrent = -5; expect(!d.isEncodable)
        var e = base(); e.negativeDeltaMillivolts = -1; expect(!e.isEncodable); expect(blockers(base()).isEmpty)
        var f = Limits.suggested(type: .liIon, mode: .charge, rated: 3000); f.chargeEndCurrent = 5000; expect(blockers(f, 3000).contains("Charge end current"))
    }
    func timeLimitFollowsCurrents() {
        var p = Limits.suggested(type: .nimh, mode: .charge, rated: 2450, cRate: 0.5); let fast = p.timeLimitMinutes
        p.chargeCurrent = 490; expect(Limits.validate(p, ratedCapacity: 2450).contains { $0.field == "Time limit" })
        p.timeLimitMinutes = Limits.suggestedTimeLimit(p, rated: 2450); expect(p.timeLimitMinutes > fast)
        expect(!Limits.validate(p, ratedCapacity: 2450).contains { $0.field == "Time limit" })
    }
    func runtimeCurrentFollowsDirection() {
        var p = Program(); p.chargeCurrent = 245; p.dischargeCurrent = 490
        let r = SlotReading(slot: 0, rawType: 3, rawMode: 2, cycle: 0, status: SlotStatus(raw: 1), elapsed: 9, millivolts: 1400, milliamps: 450, capacity: 1, temperature: 30, internalResistance: nil, source: .usb)
        expect(Limits.runtimeProblem(r, program: p) != nil)
        var d = r; d.status = SlotStatus(raw: 2); expect(Limits.runtimeProblem(d, program: p) == nil)
        var hot = r; hot.milliamps = 245; hot.temperature = 86; expect(Limits.runtimeProblem(hot, program: p) != nil); expect(Limits.runtimeProblem(hot, program: p, checkTemperature: false) == nil)
    }
    func differentChargersAreNoticed() {
        let u = SlotReading(slot: 0, rawType: 3, rawMode: 0, cycle: 0, status: SlotStatus(raw: 0), elapsed: 0, millivolts: 1360, loadedMillivolts: 1362, milliamps: 0, capacity: 0, temperature: 27.4, internalResistance: nil, source: .usb)
        var same = u; same.millivolts = 1358; same.temperature = 27; same.source = .bluetooth; expect(!Limits.looksLikeDifferentCharger(usb: u, bluetooth: same))
        var other = same; other.millivolts = 1200; expect(Limits.looksLikeDifferentCharger(usb: u, bluetooth: other))
        var empty = same; empty.millivolts = 0; expect(Limits.looksLikeDifferentCharger(usb: u, bluetooth: empty))
        var warm = same; warm.temperature = 40; expect(Limits.looksLikeDifferentCharger(usb: u, bluetooth: warm))
    }
    func aboveOneCOnlyWarns() {
        var p = Limits.suggested(type: .nimh, mode: .charge, rated: 2000); p.chargeCurrent = 3000
        expect(blockers(p, 2000).isEmpty)
        expect(Limits.validate(p, ratedCapacity: 2000).contains { $0.severity == .warning && $0.field == "Charge current" })
    }
    func capacityLimitAtRatedWarns() {
        var p = Limits.suggested(type: .nimh, mode: .charge, rated: 2450); p.capacityLimit = 2450
        expect(Limits.validate(p, ratedCapacity: 2450).contains { $0.field == "Capacity limit" })
    }
    func unsupportedTypesCannotBeProgrammed() { var p = Program(); p.type = .lto; expect(blockers(p) == ["Type"]) }
    func runtimeLimits() {
        let ok = SlotReading(slot: 0, rawType: 3, rawMode: 0, cycle: 0, status: SlotStatus(raw: 1), elapsed: 9, millivolts: 1500, milliamps: 2450, capacity: 1, temperature: 30, internalResistance: nil, source: .usb)
        var p = Program(); p.chargeCurrent = 2450
        expect(Limits.runtimeProblem(ok, program: p) == nil)
        var hot = ok; hot.temperature = 50; expect(Limits.runtimeProblem(hot, program: p) != nil)
        var over = ok; over.milliamps = 3000; expect(Limits.runtimeProblem(over, program: p) != nil)
        var volts = ok; volts.millivolts = 1800; expect(Limits.runtimeProblem(volts, program: p) != nil)
        var idle = hot; idle.status = SlotStatus(raw: 0); expect(Limits.runtimeProblem(idle, program: p) == nil)
    }
}

func reading(_ status: UInt8, t: Int, mA: Int = 1000, cap: Double = 0, mode: UInt8 = 0, mV: Int = 1400) -> SlotReading {
    SlotReading(slot: 0, rawType: 3, rawMode: mode, cycle: 0, status: SlotStatus(raw: status), elapsed: t, millivolts: mV, milliamps: mA, capacity: cap, temperature: 26, internalResistance: 30, energyMilliwattHours: nil, source: .usb)
}

struct Tracking {
    func runStartsAndFinishes() {
        var t = RunTracker()
        expect(t.ingest(reading(0, t: 0)) == [])
        expect(t.ingest(reading(1, t: 1)) == [.started(joined: false), .sample])
        expect(t.ingest(reading(1, t: 2)) == [.sample])
        expect(t.ingest(reading(4, t: 3)).last == .ended(status: SlotStatus(raw: 4), reason: .finished))
        expect(t.open == nil)
    }
    func joiningARunInProgressIsNoted() { var t = RunTracker(); expect(t.ingest(reading(1, t: 600)).first == .started(joined: true)) }
    func multiPhaseTimerResetDoesNotSplit() {
        var t = RunTracker()
        _ = t.ingest(reading(1, t: 500, mode: 4)); expect(t.ingest(reading(3, t: 1, mode: 4)) == [.sample]); expect(t.ingest(reading(1, t: 2, mode: 4)) == [.sample])
    }
    func aTransientFaultDoesNotEndARun() {
        var t = RunTracker(); _ = t.ingest(reading(1, t: 1))
        _ = t.ingest(reading(133, t: 2)); expect(t.open != nil); expect(t.ingest(reading(1, t: 3)) == [.sample])
    }
    func sustainedCutoffsAreClassified() {
        var t = RunTracker(); _ = t.ingest(reading(1, t: 1)); var last: [RunTracker.Event] = []
        for _ in 0..<5 { last = t.ingest(reading(135, t: 2)) }
        expect(last == [.ended(status: SlotStatus(raw: 135), reason: .limit)])
        var f = RunTracker(); _ = f.ingest(reading(1, t: 1))
        for _ in 0..<5 { last = f.ingest(reading(137, t: 2)) }
        expect(last == [.ended(status: SlotStatus(raw: 137), reason: .fault)])
    }
    func stoppingIsDebounced() {
        var t = RunTracker(); _ = t.ingest(reading(1, t: 1))
        for _ in 0..<4 { expect(t.ingest(reading(0, t: 1)) == []) }
        expect(t.ingest(reading(0, t: 1)) == [.ended(status: SlotStatus(raw: 0), reason: .stopped)])
    }
    func resumesAcrossRelaunch() { var t = RunTracker(resuming: .init(type: 3, mode: 0, lastElapsed: 100)); expect(t.ingest(reading(1, t: 140)) == [.sample]) }
}

struct StopRecording {
    let sent = Date(timeIntervalSince1970: 1000)
    func commandGetsCredit() {
        let c = StopRecord(source: .stopAll, time: sent)
        expect(StopRecord.attribute(command: c, lastActive: sent.addingTimeInterval(3)) == c)
        expect(StopRecord.attribute(command: c, lastActive: sent.addingTimeInterval(-600)) == c) // Connection dropped first.
        expect(StopRecord.attribute(command: c, lastActive: nil) == c)
    }
    func noCommandIsSaidPlainly() { expect(StopRecord.attribute(command: nil, lastActive: sent) == StopRecord(source: .outsideApp, time: nil)) }
    func aRunThatCarriedOnIsNotCredited() {
        let c = StopRecord(source: .slotStop, time: sent)
        expect(StopRecord.attribute(command: c, lastActive: sent.addingTimeInterval(31)) == StopRecord(source: .outsideApp, time: nil))
    }
    func tempDatabase() -> String { NSTemporaryDirectory() + "mcx-check-\(UUID().uuidString).sqlite" }
    func savedAndClearedWithTheRun() throws {
        let store = try Store(path: ":memory:")
        let id = try need(store.createRun(slot: 1, cellID: nil, type: 3, mode: 0, program: nil, started: sent, joinedAt: 0))
        let c = StopRecord(source: .safety, time: sent)
        store.noteStop(run: id, c)
        expect(store.openRun(slot: 1)?.stop == c) // Survives a relaunch before the run ends.
        store.finish(run: id, status: 0, reason: "stopped", at: sent, analysis: Analysis.analyze([]), stop: StopRecord(source: .outsideApp, time: nil))
        expect(store.runs().first?.stop == StopRecord(source: .outsideApp, time: nil))
        let other = try need(store.createRun(slot: 2, cellID: nil, type: 3, mode: 0, program: nil, started: sent, joinedAt: 0))
        store.noteStop(run: other, c)
        store.finish(run: other, status: 128, reason: "finished", at: sent, analysis: Analysis.analyze([]))
        expect(store.runs().first { $0.id == other }?.stop == nil)
    }
    func olderDatabasesUpgrade() throws {
        let path = tempDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        expect(sqlite3_open(path, &db) == SQLITE_OK)
        let old = "CREATE TABLE runs(id INTEGER PRIMARY KEY, slot INTEGER NOT NULL, cell_id INTEGER, type INTEGER NOT NULL, mode INTEGER NOT NULL, program TEXT, started REAL NOT NULL, ended REAL, end_status INTEGER, end_reason TEXT, joined_at INTEGER NOT NULL DEFAULT 0, charge_cap REAL, discharge_cap REAL, charge_wh REAL, discharge_wh REAL, ir INTEGER, coverage REAL, gap_s REAL); INSERT INTO runs(slot,type,mode,started,ended,end_reason) VALUES(1,3,0,1000,2000,'stopped');"
        expect(sqlite3_exec(db, old, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        for _ in 0..<2 { // The second open finds the columns already there.
            let store = try Store(path: path)
            expect(store.runs().count == 1); expect(store.runs().first?.endReason == "stopped"); expect(store.runs().first?.stop == nil)
        }
    }
}

struct MC5000Protocol {
    func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }
    var tested: Program {
        var p = Program(); p.type = .eneloop; p.mode = .charge; p.chargeCurrent = 200; p.dischargeCurrent = 200; p.capacityLimit = 2500
        p.chargeStopMillivolts = 1650; p.dischargeStopMillivolts = 1000; p.chargeEndCurrent = 0; p.dischargeEndCurrent = 200
        p.chargeRestMinutes = 10; p.dischargeRestMinutes = 10; p.cycles = 1; p.cycleMode = 0; p.negativeDeltaMillivolts = 5; p.trickleUnits = 0
        p.keepMillivolts = 1290; p.temperatureCutoff = 60; p.timeLimitMinutes = 30; p.eneloopType = 2
        return p
    }
    func framesMatchTheRealCharger() {
        // These frames ran on a real MC5000.
        expect(MC5000.start(tested, slot: 3) == hex("0F 2A 94 08 00 00 C8 00 C8 09 C4 06 72 03 E8 00 00 00 C8 00 0A 00 0A 01 00 05 00 05 0A 3C 00 1E 01 2C 00 05 00 00 02 00 00 00 00 DB"))
        var d = tested; d.mode = .discharge
        expect(MC5000.start(d, slot: 3) == hex("0F 2A 94 08 03 00 C8 00 C8 09 C4 06 72 03 E8 00 00 00 C8 00 0A 00 0A 01 00 05 00 05 0A 3C 00 1E 01 2C 00 05 00 00 02 00 00 00 00 DE"))
        expect(MC5000.status(slot: 0) == hex("0F 03 91 01 92")); expect(MC5000.status(slot: 3) == hex("0F 03 91 08 99"))
        expect(MC5000.stop(slot: 3) == hex("0F 03 FE 08 06"))
        expect(MC5000.isStopAck(hex("0F 04 FE 08 01 07"), slot: 3)); expect(!MC5000.isStopAck(hex("0F 04 FE 08 01 07"), slot: 0))
        expect(MC5000.isStartAck(hex("0F 04 94 08 01 9D"), slot: 3))
        expect(!MC5000.isStartAck(hex("0F 04 94 01 01 96"), slot: 3))
        expect(MC5000.isConnectedNotice(hex("0F 04 06 01 01 08")))
        // Cycle orders are numbered differently from the MC3000.
        var c = tested; c.mode = .cycle
        for (app, wire) in [(0, 0), (1, 2), (2, 1), (3, 3)] { c.cycleMode = app; expect(MC5000.start(c, slot: 0)[3 + 21] == UInt8(wire)) }
    }
    func readingsTranslate() {
        let charging = MC5000.parseStatus(hex("0F 15 91 02 03 E7 05 74 00 00 03 92 00 00 0E 7C 00 33 02 00 00 05 4F"))
        expect(charging?.slot == 1); expect(charging?.milliamps == 999); expect(charging?.millivolts == 1396); expect(charging?.capacity == 914)
        expect(charging?.elapsed == 3708); expect(charging?.internalResistance == 51); expect(charging?.status.label == "Charging"); expect(charging?.type == .eneloop); expect(charging?.hasTemperature == false)
        let idle = MC5000.parseStatus(hex("0F 15 91 08 00 00 05 78 00 00 00 00 00 00 00 00 00 00 00 00 00 05 1B"))
        expect(idle?.slot == 3); expect(idle?.status.isIdle == true); expect(idle?.millivolts == 1400); expect(idle?.internalResistance == nil)
        expect(MC5000.parseStatus(hex("0F 15 91 02 03 E7 05 74 00 00 03 92 00 00 0E 7C 00 33 02 00 00 05 50")) == nil)
        expect(MC5000.parseStatus(hex("0F 04 06 01 01 08")) == nil)
        func st(_ wire: UInt8, _ err: UInt8) -> SlotStatus {
            var b: [UInt8] = hex("0F 15 91 01 00 00 05 78 00 00 00 00 00 00 00 00 00 00") + [wire, 0, err, 5]
            b.append(Wire.checksum(b[2...]))
            return MC5000.parseStatus(b)!.status
        }
        expect(st(0, 0).isIdle); expect(st(1, 0).isIdle); expect(st(2, 0).raw == 1); expect(st(3, 0).raw == 2); expect(st(4, 0).raw == 3); expect(st(5, 0).isDone); expect(st(6, 0).isDone); expect(st(2, 7).isFault)
    }
    func normalizes() {
        var p = tested; p.capacityLimit = 0; p.chargeRestMinutes = 0; p.timeLimitMinutes = 606; p.chargeEndCurrent = 54; p.cycles = 5
        let q = MC5000.normalized(p)
        expect(q.capacityLimit == 10000); expect(q.chargeRestMinutes == 1); expect(q.timeLimitMinutes == 630); expect(q.chargeEndCurrent == 50); expect(q.cycles == 1)
        var off = p; off.timeLimitMinutes = 0; expect(MC5000.normalized(off).timeLimitMinutes == 0)
        var n = tested; n.type = .nimh; expect(MC5000.normalized(n).eneloopType == nil); expect(MC5000.start(n, slot: 0)[3 + 32] == 3)
        var e = tested; e.eneloopType = nil; expect(MC5000.normalized(e).eneloopType == MC5000.defaultEneloopType)
    }
    func validationRules() {
        func blocked(_ p: Program, _ m: ChargerModel) -> Bool { Limits.validate(p, ratedCapacity: 2500, model: m).contains { $0.severity == .blocker } }
        var base = tested; base.keepMillivolts = 1350 // The tested frame used the app's 1.29 V default, below the range offered to people.
        expect(!blocked(base, .mc5000))
        var li = base; li.type = .liIon; li.chargeStopMillivolts = 4200; li.dischargeStopMillivolts = 3000; li.keepMillivolts = 0
        expect(blocked(li, .mc5000)); expect(!blocked(li, .mc3000))
        var dv = base; dv.negativeDeltaMillivolts = 2; expect(blocked(dv, .mc5000)); expect(!blocked(dv, .mc3000))
        var cy = base; cy.mode = .cycle; cy.cycles = 4; expect(blocked(cy, .mc5000)); expect(!blocked(cy, .mc3000))
        var ds = base; ds.mode = .discharge; ds.dischargeStopMillivolts = 550; expect(blocked(ds, .mc5000))
    }
}

struct Analyzing {
    func sample(_ t: Double, _ st: UInt8, mA: Int = 1000, cap: Double, energy: Int? = nil) -> Sample {
        Sample(time: Date(timeIntervalSince1970: t), cycle: 0, status: st, elapsed: Int(t), millivolts: 1400, loadedMillivolts: nil, milliamps: mA, capacity: cap, temperature: 26, internalResistance: 30, energy: energy, source: .usb)
    }
    func capacitySurvivesPhaseResetAndStop() {
        // Capacity resets between phases, and a stopped discharge reads 0.
        let s = [sample(0, 2, cap: 0), sample(2, 2, cap: 88), sample(4, 3, mA: 0, cap: 88), sample(6, 1, cap: 0), sample(8, 1, cap: 50), sample(10, 0, mA: 0, cap: 0)]
        let a = Analysis.analyze(s)
        expect(a.phases.map(\.kind) == [.discharge, .rest, .charge]); expect(a.dischargeCapacity == 88); expect(a.chargeCapacity == 50)
    }
    func gapsAreCountedAndNotIntegrated() {
        let s = [sample(0, 1, cap: 0), sample(2, 1, cap: 1), sample(100, 1, cap: 28), sample(102, 1, cap: 29)]
        let a = Analysis.analyze(s)
        expect(a.gapCount == 1); expect(a.gapSeconds == 98); expect(a.coverage < 0.05)
        expect(a.phases[0].chargerCapacity == 29); expect(a.phases[0].calculatedCapacity < 2)
    }
    func joiningLateLowersCoverage() {
        var s = [sample(0, 1, cap: 0), sample(100, 1, cap: 1)]; s[0].elapsed = 100; s[1].elapsed = 200; s[1].time = Date(timeIntervalSince1970: 8)
        expect(Analysis.analyze(s).coverage < 0.1)
    }
    func energyAcrossConnectionChange() {
        var s = (0...100).map { i -> Sample in var x = sample(Double(i) * 2, 1, mA: 1000, cap: Double(i)); x.millivolts = 1400; x.energy = i <= 50 ? i : nil; return x }
        s[100].source = .bluetooth
        let e = Analysis.analyze(s).phases[0].energyWattHours
        expect(abs(e - 0.0778) < 0.002) // 1 A, 1.4 V, 200 s, not the 0.05 Wh the USB half reported
        s = s.map { var x = $0; x.energy = Int($0.capacity); return x }
        expect(Analysis.analyze(s).phases[0].energyWattHours == 0.1)
    }
    func efficiencyNeedsBothDirections() {
        func c(_ t: Double, _ wh: Int) -> [Sample] { [sample(t, 1, cap: 0, energy: 0), sample(t + 1, 1, cap: 10, energy: wh)] }
        func d(_ t: Double, _ wh: Int) -> [Sample] { [sample(t, 2, cap: 0, energy: 0), sample(t + 1, 2, cap: 9, energy: wh)] }
        let done = [sample(90, 4, mA: 0, cap: 9)]
        func eff(_ s: [Sample]) -> Double? { Analysis.analyze(s).efficiency }
        // One direction only, or a charge with nothing known about how full the cell was.
        expect(eff(c(0, 1000)) == nil)
        expect(eff(c(0, 500) + d(10, 800) + done) == nil)
        // Discharge, charge, discharge is a real round trip.
        expect(eff(d(0, 900) + c(10, 1000) + d(20, 800) + done) == 0.8)
        // Charge > Discharge cycles: the first charge is only a top-up, and 124% is what counting it gave.
        expect(eff(c(0, 981) + d(10, 2928) + c(20, 3715) + d(30, 2924) + done) == 2924.0 / 3715.0)
        // Rests in between change nothing.
        let rest = [sample(15, 3, mA: 0, cap: 0)], rest2 = [sample(25, 3, mA: 0, cap: 0)]
        expect(eff(d(0, 900) + rest + c(16, 1000) + rest2 + d(26, 800) + done) == 0.8)
        // A stopped or faulted last discharge falls back to the last finished pair, or to nothing.
        expect(eff(d(0, 900) + c(10, 1000) + d(20, 100)) == nil)
        expect(eff(d(0, 900) + c(10, 1000) + d(20, 100) + [sample(30, 130, mA: 0, cap: 0)]) == nil)
        expect(eff(d(0, 900) + c(10, 1000) + d(20, 800) + c(30, 1000) + d(40, 100)) == 0.8)
    }
    func downsamplingKeepsDips() {
        var s = (0..<1000).map { sample(Double($0), 1, mA: 2450, cap: 0) }; s[500].milliamps = 300
        let d = Analysis.downsample(s, max: 50)
        expect(d.contains { $0.milliamps == 300 }); expect(d.count <= 50); expect(d.contains { $0.milliamps == 2450 })
        // A dip in every bucket must not hide the normal level.
        let dips = (0..<30000).map { i in sample(Double(i), 1, mA: i % 20 == 0 ? 300 : 2450, cap: 0) }
        let e = Analysis.downsample(dips, max: 100); expect(e.filter { $0.milliamps == 2450 }.count >= 40)
        expect(zip(e, e.dropFirst()).allSatisfy { $0.time <= $1.time })
    }
    func chartLineStaysWhole() {
        // Thinned points of a long run sit far apart, and that alone must not break the line.
        let long = (0..<30000).map { sample(Double($0), $0 < 15000 ? 1 : 2, mA: 1000, cap: 0) }
        let c = Analysis.chartSegments(long, max: 1500)
        expect(c.count <= 1500); expect(Set(c.map(\.segment)).count == 2)
        // A real gap still breaks it, including one too short to see between thinned points.
        let gapped = (0..<30000).map { sample(Double($0) + ($0 >= 20000 ? 15 : 0), 1, mA: 1000, cap: 0) }
        expect(Set(Analysis.chartSegments(gapped, max: 1500).map(\.segment)).count == 2)
        expect(Set(Analysis.chartSegments(gapped, max: 40000).map(\.segment)).count == 2)
        // A gap before the first thinned point breaks nothing.
        var early = (0..<200).map { sample(Double($0) + ($0 > 0 ? 20 : 0), 1, mA: 1000, cap: 0) }
        early[5].milliamps = 500; early[6].milliamps = 1500
        expect(Set(Analysis.chartSegments(early, max: 10).map(\.segment)).count == 1)
        expect(Analysis.chartSegments([], max: 100).isEmpty)
    }
    func packMatching() {
        let c = [("E-01", 1902.0, 29), ("E-02", 1894, 31), ("E-03", 1842, 34), ("E-04", 1889, 30), ("E-05", 1776, 47), ("E-06", 1851, 33), ("E-07", 1648, 68), ("E-08", 1897, 30)].enumerated().map { Analysis.MatchCell(id: Int64($0.offset), label: $0.element.0, capacity: $0.element.1, resistance: $0.element.2) }
        let m = Analysis.packMatches(c, size: 4)
        expect(Set(m[0].cells.map(\.label)) == ["E-01", "E-08", "E-02", "E-04"]); expect(m[0].capacitySpread == 13); expect(m[0].resistanceSpread == 2); expect(m[0].limitedBy.label == "E-04")
    }
    func csvHasEveryRow() { expect(Analysis.csv([sample(0, 1, cap: 1)]).split(separator: "\n").count == 2) }
}

func run(_ name: String, _ f: () throws -> Void) { do { try f() } catch { failures += 1; print("FAILED \(name): \(error)") } }
run("Decoding.bluetoothStatus") { try Decoding().bluetoothStatus() }
run("Decoding.bluetoothRejectsBadChecksum") { Decoding().bluetoothRejectsBadChecksum() }
run("Decoding.version") { try Decoding().version() }
run("Decoding.usbLive") { try Decoding().usbLive() }
run("Programs.bluetoothMatchesAcceptedFrame") { Programs().bluetoothMatchesAcceptedFrame() }
run("Programs.usbReplyDecodes") { Programs().usbReplyDecodes() }
run("Programs.usbFrameIsARepackOfTheRead") { Programs().usbFrameIsARepackOfTheRead() }
run("Programs.liIonResetIsDetected") { Programs().liIonResetIsDetected() }
run("LimitChecks.onecDischargeIsBlocked") { LimitChecks().onecDischargeIsBlocked() }
run("LimitChecks.unsafeValuesThatBluetoothWouldStoreAreBlocked") { LimitChecks().unsafeValuesThatBluetoothWouldStoreAreBlocked() }
run("LimitChecks.officialAppLimits") { LimitChecks().officialAppLimits() }
run("LimitChecks.breakInSuggestsSlowCurrentsAndWarns") { LimitChecks().breakInSuggestsSlowCurrentsAndWarns() }
run("LimitChecks.everyEncodedFieldIsChecked") { LimitChecks().everyEncodedFieldIsChecked() }
run("LimitChecks.timeLimitFollowsCurrents") { LimitChecks().timeLimitFollowsCurrents() }
run("LimitChecks.runtimeCurrentFollowsDirection") { LimitChecks().runtimeCurrentFollowsDirection() }
run("LimitChecks.differentChargersAreNoticed") { LimitChecks().differentChargersAreNoticed() }
run("LimitChecks.aboveOneCOnlyWarns") { LimitChecks().aboveOneCOnlyWarns() }
run("LimitChecks.capacityLimitAtRatedWarns") { LimitChecks().capacityLimitAtRatedWarns() }
run("LimitChecks.unsupportedTypesCannotBeProgrammed") { LimitChecks().unsupportedTypesCannotBeProgrammed() }
run("LimitChecks.runtimeLimits") { LimitChecks().runtimeLimits() }
run("Tracking.runStartsAndFinishes") { Tracking().runStartsAndFinishes() }
run("Tracking.joiningARunInProgressIsNoted") { Tracking().joiningARunInProgressIsNoted() }
run("Tracking.multiPhaseTimerResetDoesNotSplit") { Tracking().multiPhaseTimerResetDoesNotSplit() }
run("Tracking.aTransientFaultDoesNotEndARun") { Tracking().aTransientFaultDoesNotEndARun() }
run("Tracking.sustainedCutoffsAreClassified") { Tracking().sustainedCutoffsAreClassified() }
run("Tracking.stoppingIsDebounced") { Tracking().stoppingIsDebounced() }
run("Tracking.resumesAcrossRelaunch") { Tracking().resumesAcrossRelaunch() }
run("StopRecording.commandGetsCredit") { StopRecording().commandGetsCredit() }
run("StopRecording.noCommandIsSaidPlainly") { StopRecording().noCommandIsSaidPlainly() }
run("StopRecording.aRunThatCarriedOnIsNotCredited") { StopRecording().aRunThatCarriedOnIsNotCredited() }
run("StopRecording.savedAndClearedWithTheRun") { try StopRecording().savedAndClearedWithTheRun() }
run("StopRecording.olderDatabasesUpgrade") { try StopRecording().olderDatabasesUpgrade() }
run("Analyzing.capacitySurvivesPhaseResetAndStop") { Analyzing().capacitySurvivesPhaseResetAndStop() }
run("Analyzing.gapsAreCountedAndNotIntegrated") { Analyzing().gapsAreCountedAndNotIntegrated() }
run("Analyzing.joiningLateLowersCoverage") { Analyzing().joiningLateLowersCoverage() }
run("Analyzing.energyAcrossConnectionChange") { Analyzing().energyAcrossConnectionChange() }
run("Analyzing.efficiencyNeedsBothDirections") { Analyzing().efficiencyNeedsBothDirections() }
run("Analyzing.downsamplingKeepsDips") { Analyzing().downsamplingKeepsDips() }
run("Analyzing.chartLineStaysWhole") { Analyzing().chartLineStaysWhole() }
run("MC5000Protocol.framesMatchTheRealCharger") { MC5000Protocol().framesMatchTheRealCharger() }
run("MC5000Protocol.readingsTranslate") { MC5000Protocol().readingsTranslate() }
run("MC5000Protocol.normalizes") { MC5000Protocol().normalizes() }
run("MC5000Protocol.validationRules") { MC5000Protocol().validationRules() }
run("Analyzing.packMatching") { Analyzing().packMatching() }
run("Analyzing.csvHasEveryRow") { Analyzing().csvHasEveryRow() }
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
