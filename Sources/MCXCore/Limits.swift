import Foundation

public struct ProgramIssue: Equatable, Identifiable, Sendable {
    public enum Severity: Sendable { case blocker, warning }
    public let severity: Severity
    public let field: String
    public let message: String
    public var id: String { field + message }
}

/// The charger trusts what it's sent: Bluetooth stores out-of-range values as written, and USB swaps in
/// Li-ion defaults. These checks are the real protection, so anything past a limit blocks the write.
public enum Limits {
    public static let maxChargeCurrent = 3000
    public static let maxDischargeCurrent = 2000
    public static let minCurrent = 50
    /// Total discharge power the charger is rated for, across all slots.
    public static let maxDischargeWatts = 15.0

    /// Ranges and defaults from SkyRC's own MC3000 Android app (v4.1.2, `Constant` tables).
    public struct VoltageRange: Sendable {
        public let chargeStop: ClosedRange<Int>; public let dischargeStop: ClosedRange<Int>; public let keep: ClosedRange<Int>
        public let chargeTypical: Int; public let dischargeTypical: Int; public let keepTypical: Int
    }

    public static func voltages(for t: BatteryType) -> VoltageRange? {
        switch t {
        case .nimh, .nicd: VoltageRange(chargeStop: 1470...1800, dischargeStop: 500...1100, keep: 1300...1450, chargeTypical: 1650, dischargeTypical: 1000, keepTypical: 1350)
        case .eneloop: VoltageRange(chargeStop: 1470...1800, dischargeStop: 500...1000, keep: 1300...1450, chargeTypical: 1650, dischargeTypical: 900, keepTypical: 1350)
        case .liIon: VoltageRange(chargeStop: 4000...4250, dischargeStop: 2500...3650, keep: 3980...4180, chargeTypical: 4200, dischargeTypical: 3000, keepTypical: 4150)
        case .liFe: VoltageRange(chargeStop: 3400...3650, dischargeStop: 2000...3150, keep: 3380...3580, chargeTypical: 3600, dischargeTypical: 2900, keepTypical: 3550)
        case .li435: VoltageRange(chargeStop: 4100...4400, dischargeStop: 2650...3750, keep: 4080...4330, chargeTypical: 4350, dischargeTypical: 3300, keepTypical: 4250)
        default: nil
        }
    }
    /// Storage mode charges to a storage voltage instead, on the lithium types.
    public static func storageVoltage(for t: BatteryType) -> (range: ClosedRange<Int>, typical: Int)? {
        switch t {
        case .liIon: (3650...4000, 3800)
        case .liFe: (3150...3400, 3300)
        case .li435: (3750...4100, 3900)
        default: nil
        }
    }

    public static func validate(_ p: Program, ratedCapacity rated: Int) -> [ProgramIssue] {
        var out: [ProgramIssue] = []
        func block(_ f: String, _ m: String) { out.append(.init(severity: .blocker, field: f, message: m)) }
        func warn(_ f: String, _ m: String) { out.append(.init(severity: .warning, field: f, message: m)) }

        guard p.type.canProgram, let v = voltages(for: p.type) else {
            block("Type", "\(p.type.name) can be monitored, but the app can't program it yet.")
            return out
        }
        if rated <= 0 { block("Rated capacity", "Enter the cell's rated capacity.") }
        if !p.isEncodable { block("Program", "A value is negative or too large. Check every field, including any that aren't shown for this mode.") }

        if p.mode == .storageOrBreakIn && p.type.isNickel && rated > 0 && p.chargeCurrent > rated / 10 + rated / 50 {
            warn("Charge current", String(format: "Break-in is normally a long charge at about 0.1C (%d mA). This is %.1fC, and it may not stop when the cell is full. Watch the cell closely.", rated / 10, Double(p.chargeCurrent) / Double(rated)))
        }
        if p.mode.charges {
            if p.chargeCurrent < minCurrent || p.chargeCurrent > maxChargeCurrent {
                block("Charge current", "Must be \(minCurrent)–\(maxChargeCurrent) mA. The charger's maximum is 3,000 mA.")
            } else if rated > 0 {
                let c = Double(p.chargeCurrent) / Double(rated)
                if p.type.isNickel && c > 1.0 { warn("Charge current", String(format: "%.1fC is above the usual 1C for this type. Watch the cell's temperature.", c)) }
                if p.type.isLithium && c > 1.0 { warn("Charge current", String(format: "%.1fC is above the usual 1C for lithium cells unless the datasheet allows it.", c)) }
            }
            let storage = p.mode == .storageOrBreakIn ? storageVoltage(for: p.type) : nil
            let stopRange = storage?.range ?? v.chargeStop, stopTypical = storage?.typical ?? v.chargeTypical
            if !stopRange.contains(p.chargeStopMillivolts) {
                block("Charge stop", "Must be \(Format.volts(stopRange.lowerBound))–\(Format.volts(stopRange.upperBound)) for \(p.type.name).")
            } else if p.chargeStopMillivolts > stopTypical {
                warn("Charge stop", "Above the usual \(Format.volts(stopTypical)) for \(p.type.name). Only use this if the cell's datasheet allows it.")
            }
            if p.type.isNickel {
                if p.negativeDeltaMillivolts > 20 { block("-dV", "Must be 0–20 mV.") }
                else if p.negativeDeltaMillivolts == 0 { warn("-dV", "Off means the charge relies on its voltage, capacity, time and temperature limits to stop.") }
            }
            if p.keepMillivolts != 0 && !v.keep.contains(p.keepMillivolts) {
                block("Keep voltage", "Must be Off or \(Format.volts(v.keep.lowerBound))–\(Format.volts(v.keep.upperBound)) for \(p.type.name).")
            }
            if p.trickleUnits > 30 { block("Trickle", "Must be 0–300 mA.") }
            if p.chargeEndCurrent > p.chargeCurrent { block("Charge end current", "Can't be higher than the charge current.") }
            if p.capacityLimit > 0 && rated > 0 && p.capacityLimit <= rated {
                warn("Capacity limit", "The run ends at \(p.capacityLimit) mAh, which could cut a charge short. For benchmarks, use about 120% of rated, or Off.")
            }
        }
        if p.mode.discharges {
            if p.dischargeCurrent < minCurrent || p.dischargeCurrent > maxDischargeCurrent {
                block("Discharge current", "Must be \(minCurrent)–\(maxDischargeCurrent) mA. The fastest this charger allows is 2,000 mA.")
            }
            if !v.dischargeStop.contains(p.dischargeStopMillivolts) {
                block("Discharge stop", "Must be \(Format.volts(v.dischargeStop.lowerBound))–\(Format.volts(v.dischargeStop.upperBound)) for \(p.type.name).")
            } else if p.dischargeStopMillivolts < v.dischargeTypical {
                warn("Discharge stop", "Below the usual \(Format.volts(v.dischargeTypical)) for \(p.type.name). Deep discharge can damage a cell.")
            }
            if p.dischargeEndCurrent > p.dischargeCurrent {
                block("Discharge end current", "Can't be higher than the discharge current.")
            }
            let watts = Double(p.dischargeCurrent) / 1000 * Double(v.dischargeStop.upperBound) / 1000
            if p.type.isLithium && watts > maxDischargeWatts / 4 {
                warn("Discharge current", "Discharging several lithium cells at this rate may exceed the charger's 15 W total.")
            }
        }
        if p.capacityLimit < 0 || p.capacityLimit > 50000 { block("Capacity limit", "Must be 0–50,000 mAh.") }
        if p.temperatureCutoff < 20 || p.temperatureCutoff > 70 {
            block("Temperature cutoff", "Must be 20–70 °C.")
        } else if p.temperatureCutoff > 50 {
            warn("Temperature cutoff", "\(p.temperatureCutoff) °C is warm for a cell. 45 °C is the usual cutoff.")
        }
        if p.timeLimitMinutes > 1440 { block("Time limit", "Must be 1,440 minutes or less.") }
        if p.timeLimitMinutes == 0 { warn("Time limit", "Off means no time backstop if the charger misses the end of charge.") }
        if p.timeLimitMinutes > 0, let estimate = estimatedMinutes(p, rated: rated), Double(p.timeLimitMinutes) < estimate {
            warn("Time limit", "A full run at these currents may take about \(Int(estimate)) minutes, so this limit could end it early.")
        }
        if p.cycles < 1 || p.cycles > 99 { block("Cycles", "Must be 1–99.") }
        if p.cycleMode > 3 { block("Cycle order", "Pick an order from the list.") }
        if p.chargeRestMinutes > 240 || p.dischargeRestMinutes > 240 { block("Rest", "Rest must be 240 minutes or less.") }
        return out
    }

    /// Roughly how long a full run takes, ignoring cycle counts beyond the first. nil without enough to go on.
    public static func estimatedMinutes(_ p: Program, rated: Int) -> Double? {
        guard rated > 0, p.chargeCurrent > 0, p.dischargeCurrent > 0 else { return nil }
        let charge = Double(rated) / Double(p.chargeCurrent) * 60, discharge = Double(rated) / Double(p.dischargeCurrent) * 60
        switch p.mode {
        case .charge: return charge
        case .discharge: return discharge
        case .storageOrBreakIn: return p.type.isNickel ? nil : charge
        case .refresh, .cycle: return charge * 2 + discharge
        }
    }
    /// A backstop with some margin: well past a normal run, but still a limit.
    public static func suggestedTimeLimit(_ p: Program, rated: Int) -> Int {
        guard let e = estimatedMinutes(p, rated: rated) else { return 0 }
        return min(1440, Int(e * 1.6) + 30)
    }

    /// True when the same slot reads too differently over USB and Bluetooth to be the same cell in the same charger.
    public static func looksLikeDifferentCharger(usb: SlotReading, bluetooth: SlotReading) -> Bool {
        if usb.hasCell != bluetooth.hasCell { return true }
        if abs(usb.temperature - bluetooth.temperature) > 5 { return true }
        let tolerance = usb.status.isActive || bluetooth.status.isActive ? 200 : 100
        return usb.hasCell && abs(usb.millivolts - bluetooth.millivolts) > tolerance
    }

    /// A sensible starting point for a cell, at the given C-rate where the charger allows it.
    public static func suggested(type: BatteryType, mode: ChargeMode, rated: Int, cRate: Double = 0.5) -> Program {
        var p = Program()
        p.type = type; p.mode = mode
        let v = voltages(for: type) ?? voltages(for: .nimh)!
        let i = Int((Double(rated) * cRate).rounded())
        p.chargeCurrent = min(max(i, minCurrent), maxChargeCurrent)
        p.dischargeCurrent = min(max(i, minCurrent), maxDischargeCurrent)
        p.dischargeEndCurrent = p.dischargeCurrent
        p.chargeStopMillivolts = (mode == .storageOrBreakIn ? storageVoltage(for: type)?.typical : nil) ?? v.chargeTypical
        p.dischargeStopMillivolts = v.dischargeTypical
        p.chargeEndCurrent = type.isLithium ? max(50, rated / 20) : 50
        p.keepMillivolts = type.isNickel ? v.keepTypical : 0
        p.negativeDeltaMillivolts = 3
        p.capacityLimit = mode == .discharge ? 0 : Int(Double(rated) * 1.2)
        if mode == .storageOrBreakIn && type.isNickel {
            // SkyRC's app derives break-in currents from capacity: a slow 0.1C charge and a 0.2C discharge.
            p.chargeCurrent = max(minCurrent, rated / 10)
            p.dischargeCurrent = max(minCurrent, rated / 5)
            p.dischargeEndCurrent = p.dischargeCurrent
            p.capacityLimit = rated
            p.timeLimitMinutes = 0
            return p
        }
        p.temperatureCutoff = 45
        p.timeLimitMinutes = suggestedTimeLimit(p, rated: rated)
        return p
    }

    /// Hard limits while a slot runs. A breach on consecutive readings stops the slot.
    public static func runtimeProblem(_ r: SlotReading, program: Program?, checkTemperature: Bool = true) -> String? {
        guard r.status.isActive else { return nil }
        let type = r.type
        let typeMax = type?.isNickel == true ? 1850 : type == .li435 ? 4450 : type?.isLithium == true ? 4300 : 5000
        let maxMV = program.map { $0.chargeStopMillivolts + 120 } ?? typeMax
        if r.millivolts > maxMV { return "voltage reached \(Format.volts(r.millivolts))" }
        let cutoff = Double(program?.temperatureCutoff ?? 55)
        if checkTemperature, r.temperature >= cutoff + 5 { return String(format: "temperature reached %.1f °C", r.temperature) }
        // Judged against the direction the slot is actually running in.
        let target = program.map { r.status.raw == 2 ? $0.dischargeCurrent : r.status.raw == 1 ? $0.chargeCurrent : 0 }
        let maxI = target.map { $0 + max(150, $0 / 10) } ?? 3300
        if r.milliamps > maxI { return "current reached \(r.milliamps) mA" }
        return nil
    }
}
