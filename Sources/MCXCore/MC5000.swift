import Foundation

public enum ChargerModel: String, Sendable {
    case mc3000, mc5000
    public var name: String { self == .mc3000 ? "MC3000" : "MC5000" }
}

/// The MC5000's Bluetooth protocol. Only the operations below can be built, so its firmware update, reset and
/// password commands cannot be sent by this app. Status, stop and start were confirmed on a real charger.
/// Readings are translated into the MC3000's type, mode and status codes, so the rest of the app treats both alike.
public enum MC5000 {
    public static let eneloopTypes = ["Std AA", "Std AAA", "Pro/XX AA", "Pro/XX AAA", "Lite AA", "Lite AAA", "Plus AA", "Std C", "Std D"]
    /// Pro/XX AA, the type tested on the charger.
    public static let defaultEneloopType = 2
    public static func canProgram(_ t: BatteryType) -> Bool { t == .nimh || t == .eneloop || t.isLithium }

    /// SkyRC's MC5000 limits, tighter in places than the MC3000's.
    struct LithiumRange { let charge: ClosedRange<Int>; let discharge: ClosedRange<Int>; let storage: ClosedRange<Int>; let typicalCharge: Int; let typicalStorage: Int }
    static func lithiumRange(_ t: BatteryType) -> LithiumRange? {
        switch t {
        case .liIon: LithiumRange(charge: 4050...4250, discharge: 2500...3300, storage: 3700...3850, typicalCharge: 4200, typicalStorage: 3800)
        case .li435: LithiumRange(charge: 4250...4400, discharge: 2600...3800, storage: 3850...3950, typicalCharge: 4350, typicalStorage: 3900)
        case .liFe: LithiumRange(charge: 3580...3700, discharge: 2600...3000, storage: 3250...3400, typicalCharge: 3650, typicalStorage: 3300)
        default: nil
        }
    }

    static func mask(_ slot: Int) -> UInt8 { UInt8(1 << slot) }
    static func slot(mask: UInt8) -> Int? { [1: 0, 2: 1, 4: 2, 8: 3][mask] }

    private static func frame(_ op: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [0x0F, UInt8(payload.count + 2), op] + payload + [Wire.checksum([op] + payload)]
    }
    private static func valid(_ r: [UInt8]) -> Bool {
        r.count >= 5 && r[0] == 0x0F && Int(r[1]) == r.count - 2 && Wire.checksum(r[2..<(r.count - 1)]) == r[r.count - 1]
    }

    public static func status(slot: Int) -> [UInt8] { frame(0x91, [mask(slot)]) }
    public static func stop(slot: Int) -> [UInt8] { frame(0xFE, [mask(slot)]) }
    public static func isStatus(_ r: [UInt8], slot: Int) -> Bool { r.count == 23 && r[2] == 0x91 && r[3] == mask(slot) }
    /// The charger answers the first command after connecting with this instead of its normal reply.
    public static func isConnectedNotice(_ r: [UInt8]) -> Bool { r == [0x0F, 0x04, 0x06, 0x01, 0x01, 0x08] }
    private static func isAck(_ r: [UInt8], op: UInt8, slot: Int) -> Bool { r.count == 6 && valid(r) && r[2] == op && r[3] == mask(slot) && r[4] == 1 }
    public static func isStopAck(_ r: [UInt8], slot: Int) -> Bool { isAck(r, op: 0xFE, slot: slot) }
    public static func isStartAck(_ r: [UInt8], slot: Int) -> Bool { isAck(r, op: 0x94, slot: slot) }

    static func appType(wire: UInt8) -> UInt8 {
        switch wire {
        case 1: BatteryType.li435.rawValue
        case 2: BatteryType.liFe.rawValue
        case 5: BatteryType.eneloop.rawValue
        case 6: BatteryType.nizn.rawValue
        default: wire
        }
    }
    static func wireType(_ t: BatteryType) -> UInt8 {
        switch t {
        case .li435: 1
        case .liFe: 2
        case .eneloop: 5
        case .nizn: 6
        default: t.rawValue
        }
    }
    /// 0 idle and 1 getting ready map to Stand-by, then 2 charging, 3 discharging, 4 resting and 5 or 6 done. A slot's error code takes priority.
    /// The MC5000 numbers modes separately for each group of cell types, leaving out the modes a group doesn't have.
    private static func modeList(wireType: UInt8) -> [ChargeMode] {
        switch wireType {
        case 0, 1, 2, 8, 9: [.charge, .storageOrBreakIn, .discharge, .cycle]
        case 6, 7: [.charge, .discharge, .cycle]
        default: [.charge, .refresh, .storageOrBreakIn, .discharge, .cycle]
        }
    }
    static func appMode(wire: UInt8, wireType: UInt8) -> UInt8 {
        let list = modeList(wireType: wireType)
        return Int(wire) < list.count ? list[Int(wire)].rawValue : wire
    }
    static func wireMode(_ m: ChargeMode, type: BatteryType) -> UInt8? { modeList(wireType: wireType(type)).firstIndex(of: m).map { UInt8($0) } }

    static func appStatus(wire: UInt8, error: UInt8) -> SlotStatus {
        if error != 0 { return SlotStatus(raw: UInt8(min(255, 200 + Int(error)))) }
        switch wire {
        case 2: return SlotStatus(raw: 1)
        case 3: return SlotStatus(raw: 2)
        case 4: return SlotStatus(raw: 3)
        case 5, 6: return SlotStatus(raw: 4)
        default: return SlotStatus(raw: 0)
        }
    }

    public static func parseStatus(_ r: [UInt8]) -> SlotReading? {
        guard r.count == 23, valid(r), r[2] == 0x91, let slot = slot(mask: r[3]) else { return nil }
        func u(_ i: Int) -> Int { Int(r[i]) << 8 | Int(r[i + 1]) }
        let ir = u(16)
        // There is no cell temperature sensor on the charger, so temperature stays 0 and is shown as unknown.
        return SlotReading(slot: slot, rawType: appType(wire: r[21]), rawMode: appMode(wire: r[19], wireType: r[21]), cycle: 0, status: appStatus(wire: r[18], error: r[20]),
                           elapsed: u(12) << 16 | u(14), millivolts: u(6), milliamps: u(4), capacity: Double(u(10)), temperature: 0,
                           internalResistance: ir == 0 ? nil : ir, source: .bluetooth)
    }

    /// The program as it will really be sent: the charger only takes these steps and ranges, and every field is written even when the mode doesn't use it.
    public static func normalized(_ p: Program) -> Program {
        func up(_ v: Int, _ step: Int) -> Int { (v + step - 1) / step * step }
        var q = p
        q.capacityLimit = p.capacityLimit == 0 ? 10000 : min(10000, max(100, up(p.capacityLimit, 100)))
        q.chargeRestMinutes = min(120, max(1, p.chargeRestMinutes))
        q.dischargeRestMinutes = min(120, max(1, p.dischargeRestMinutes))
        q.timeLimitMinutes = p.timeLimitMinutes == 0 ? 0 : min(1440, up(p.timeLimitMinutes, 30))
        q.chargeEndCurrent = min(990, (p.chargeEndCurrent + 5) / 10 * 10)
        if p.mode != .cycle { q.cycles = 1 }
        // These only apply to nickel cells, but every field is written. 6 mV is SkyRC's default.
        if p.type.isLithium { q.negativeDeltaMillivolts = 6; q.trickleUnits = 0 }
        if p.type == .eneloop { q.eneloopType = p.eneloopType ?? defaultEneloopType } else { q.eneloopType = nil }
        return q
    }

    /// Writing this frame starts the slot straight away; there is no separate start command. nil if this cell type doesn't have that mode.
    public static func start(_ program: Program, slot: Int) -> [UInt8]? {
        let p = normalized(program)
        guard let mode = wireMode(p.mode, type: p.type) else { return nil }
        // Storage has its own target. The app keeps it in the charge stop field, as it does on the MC3000.
        let range = lithiumRange(p.type), storing = p.mode == .storageOrBreakIn && range != nil
        var d = [UInt8](repeating: 0, count: 40)
        func put(_ i: Int, _ v: Int) { d[i] = UInt8((v >> 8) & 255); d[i + 1] = UInt8(v & 255) }
        d[0] = mask(slot); d[1] = mode
        put(2, p.chargeCurrent); put(4, p.dischargeCurrent); put(6, p.capacityLimit)
        put(8, storing ? range!.typicalCharge : p.chargeStopMillivolts); put(10, p.dischargeStopMillivolts)
        put(12, p.chargeEndCurrent); put(14, p.dischargeEndCurrent == 0 ? p.dischargeCurrent : p.dischargeEndCurrent)
        put(16, p.chargeRestMinutes); put(18, p.dischargeRestMinutes)
        d[20] = UInt8(clamping: p.cycles)
        // The MC3000 orders these C>D, C>D>C, D>C, D>C>D. The MC5000 orders them C>D, D>C, C>D>C, D>C>D.
        d[21] = [0, 2, 1, 3][min(3, max(0, p.cycleMode))]
        d[22] = UInt8(clamping: p.negativeDeltaMillivolts); d[23] = UInt8(clamping: p.trickleUnits)
        put(24, p.keepMillivolts == 0 ? 1290 : p.keepMillivolts)
        d[26] = UInt8(clamping: p.temperatureCutoff); put(27, p.timeLimitMinutes); put(29, 300)
        d[32] = wireType(p.type); d[35] = UInt8(clamping: p.eneloopType ?? 0)
        put(33, storing ? p.chargeStopMillivolts : range?.typicalStorage ?? 0)
        return frame(0x94, d)
    }

    /// Extra rules on top of the shared checks. These come from SkyRC's own MC5000 screens.
    static func issues(_ p: Program) -> [ProgramIssue] {
        var out: [ProgramIssue] = []
        func block(_ f: String, _ m: String) { out.append(.init(severity: .blocker, field: f, message: m)) }
        if let r = lithiumRange(p.type) {
            if p.mode == .refresh { block("Mode", "Refresh isn't available for lithium cells on the MC5000.") }
            func v(_ x: ClosedRange<Int>) -> String { "\(Format.volts(x.lowerBound))–\(Format.volts(x.upperBound))" }
            if p.mode == .storageOrBreakIn {
                if !r.storage.contains(p.chargeStopMillivolts) { block("Charge stop", "Storage voltage must be \(v(r.storage)) for \(p.type.name) on the MC5000.") }
            } else if p.mode.charges && !r.charge.contains(p.chargeStopMillivolts) { block("Charge stop", "Must be \(v(r.charge)) for \(p.type.name) on the MC5000.") }
            if p.mode.discharges && !r.discharge.contains(p.dischargeStopMillivolts) { block("Discharge stop", "Must be \(v(r.discharge)) for \(p.type.name) on the MC5000.") }
            if p.mode.charges && p.chargeEndCurrent < 50 { block("Charge end current", "Must be at least 50 mA for lithium cells, so the charge can finish.") }
        }
        if p.type.isNickel && p.mode.discharges && !(600...1000).contains(p.dischargeStopMillivolts) { block("Discharge stop", "Must be 0.600–1.000 V on the MC5000.") }
        if p.type.isNickel && p.mode.charges {
            if !(3...12).contains(p.negativeDeltaMillivolts) { block("-dV", "Must be 3–12 mV on the MC5000.") }
            if p.trickleUnits != 0 && !(5...30).contains(p.trickleUnits) { block("Trickle", "Must be off or 50–300 mA on the MC5000.") }
        }
        if p.mode == .cycle && !(1...3).contains(p.cycles) { block("Cycles", "Must be 1–3 on the MC5000.") }
        if p.chargeRestMinutes > 120 || p.dischargeRestMinutes > 120 { block("Rest", "Rest must be 120 minutes or less on the MC5000.") }
        return out
    }
}
