// Standalone checks for the core logic, using frames captured from a real MC3000. Run: swift run MCXCoreCheck
var failures = 0, checks = 0
func expect(_ ok: Bool, line: Int = #line) { checks += 1; if !ok { failures += 1; print("FAILED at line \(line)") } }
struct Missing: Error {}
func need<T>(_ v: T?) throws -> T { guard let v else { throw Missing() }; return v }
import Foundation
import MCXCore

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
        let s = [sample(0, 1, cap: 0, energy: 0), sample(2, 1, cap: 10, energy: 1000), sample(4, 2, cap: 0, energy: 0), sample(6, 2, cap: 9, energy: 800)]
        expect(Analysis.analyze(s).efficiency == 0.8)
        expect(Analysis.analyze(Array(s[0..<2])).efficiency == nil)
    }
    func downsamplingKeepsDips() {
        var s = (0..<1000).map { sample(Double($0), 1, mA: 2450, cap: 0) }; s[500].milliamps = 300
        expect(Analysis.downsample(s, max: 50).contains { $0.milliamps == 300 })
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
run("Analyzing.capacitySurvivesPhaseResetAndStop") { Analyzing().capacitySurvivesPhaseResetAndStop() }
run("Analyzing.gapsAreCountedAndNotIntegrated") { Analyzing().gapsAreCountedAndNotIntegrated() }
run("Analyzing.joiningLateLowersCoverage") { Analyzing().joiningLateLowersCoverage() }
run("Analyzing.energyAcrossConnectionChange") { Analyzing().energyAcrossConnectionChange() }
run("Analyzing.efficiencyNeedsBothDirections") { Analyzing().efficiencyNeedsBothDirections() }
run("Analyzing.downsamplingKeepsDips") { Analyzing().downsamplingKeepsDips() }
run("Analyzing.packMatching") { Analyzing().packMatching() }
run("Analyzing.csvHasEveryRow") { Analyzing().csvHasEveryRow() }
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
