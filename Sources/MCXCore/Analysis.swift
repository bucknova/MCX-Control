import Foundation

public struct Sample: Equatable, Sendable {
    public var time: Date
    public var cycle: Int
    public var status: UInt8
    public var elapsed: Int
    public var millivolts: Int
    public var loadedMillivolts: Int?
    public var milliamps: Int
    public var capacity: Double
    public var temperature: Double
    public var internalResistance: Int?
    public var energy: Int?
    public var source: DataSource
    public init(time: Date, cycle: Int, status: UInt8, elapsed: Int, millivolts: Int, loadedMillivolts: Int?, milliamps: Int, capacity: Double, temperature: Double, internalResistance: Int?, energy: Int?, source: DataSource) {
        self.time = time; self.cycle = cycle; self.status = status; self.elapsed = elapsed; self.millivolts = millivolts; self.loadedMillivolts = loadedMillivolts
        self.milliamps = milliamps; self.capacity = capacity; self.temperature = temperature; self.internalResistance = internalResistance; self.energy = energy; self.source = source
    }
    public init(reading r: SlotReading, at t: Date) {
        self.init(time: t, cycle: r.cycle, status: r.status.raw, elapsed: r.elapsed, millivolts: r.millivolts, loadedMillivolts: r.loadedMillivolts, milliamps: r.milliamps, capacity: r.capacity, temperature: r.temperature, internalResistance: r.internalResistance, energy: r.energyMilliwattHours, source: r.source)
    }
}

public struct Phase: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case charge = "Charge", discharge = "Discharge", rest = "Rest" }
    public let kind: Kind
    public let start: Date
    public let end: Date
    public let chargerCapacity: Double
    public let calculatedCapacity: Double
    public let energyWattHours: Double
    public let averageCurrent: Int
    public let voltageRange: ClosedRange<Int>
    public let peakTemperature: Double
    public let internalResistance: Int?
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var id: Date { start }
}

public struct RunAnalysis: Equatable, Sendable {
    public let phases: [Phase]
    public let gapSeconds: Double
    public let gapCount: Int
    public let coverage: Double
    public var chargeCapacity: Double { phases.filter { $0.kind == .charge }.map(\.chargerCapacity).reduce(0, +) }
    public var dischargeCapacity: Double? { phases.last { $0.kind == .discharge }?.chargerCapacity }
    public var chargeEnergy: Double { phases.filter { $0.kind == .charge }.map(\.energyWattHours).reduce(0, +) }
    public var dischargeEnergy: Double { phases.filter { $0.kind == .discharge }.map(\.energyWattHours).reduce(0, +) }
    /// Only meaningful with both directions; a cell's first charge isn't necessarily what came out.
    public var efficiency: Double? {
        guard let first = phases.firstIndex(where: { $0.kind == .charge }), let disch = phases.lastIndex(where: { $0.kind == .discharge }), first < disch, chargeEnergy > 0 else { return nil }
        let inEnergy = phases[first...disch].filter { $0.kind == .charge }.map(\.energyWattHours).reduce(0, +)
        let outEnergy = phases[first...disch].filter { $0.kind == .discharge }.map(\.energyWattHours).reduce(0, +)
        return inEnergy > 0 ? outEnergy / inEnergy : nil
    }
    public var internalResistance: Int? { phases.reversed().compactMap(\.internalResistance).first }
}

public enum Analysis {
    /// A gap longer than this means readings were lost, not just slow. Bluetooth/USB switches and the
    /// few-second USB stall after a start land under or just over it.
    public static let gapThreshold: TimeInterval = 10

    public static func analyze(_ samples: [Sample]) -> RunAnalysis {
        var phases: [Phase] = []
        var gap = 0.0, gaps = 0
        var group: [Sample] = []
        func kind(_ s: UInt8) -> Phase.Kind? { s == 1 ? .charge : s == 2 ? .discharge : s == 3 ? .rest : nil }
        func flush() {
            guard let f = group.first, let l = group.last, let k = kind(f.status) else { group = []; return }
            var calc = 0.0, wh = 0.0
            var hasCharger = false
            var maxEnergy = 0, firstEnergy: Int?
            for (a, b) in zip(group, group.dropFirst()) {
                let dt = b.time.timeIntervalSince(a.time)
                if dt <= gapThreshold {
                    let mA = Double(a.milliamps + b.milliamps) / 2
                    calc += mA * dt / 3600
                    let mV = Double((a.loadedMillivolts ?? a.millivolts) + (b.loadedMillivolts ?? b.millivolts)) / 2
                    wh += mA / 1000 * mV / 1000 * dt / 3600
                }
            }
            var allHaveCharger = true
            for s in group { if let e = s.energy { hasCharger = true; maxEnergy = max(maxEnergy, e); if firstEnergy == nil { firstEnergy = e } } else { allHaveCharger = false } }
            // The charger's energy counter only arrives over USB. If a phase changed connection partway, its last value
            // covers only part of the phase, so the calculated figure is the better one.
            let energy = hasCharger && allHaveCharger ? Double(maxEnergy) / 1000 : wh
            let volts = group.map(\.millivolts)
            let running = group.filter { $0.milliamps > 0 }
            let current = running.isEmpty ? 0 : running.map(\.milliamps).reduce(0, +) / running.count
            phases.append(Phase(kind: k, start: f.time, end: l.time, chargerCapacity: group.map(\.capacity).max() ?? 0, calculatedCapacity: calc, energyWattHours: k == .rest ? 0 : energy, averageCurrent: current, voltageRange: (volts.min() ?? 0)...(volts.max() ?? 0), peakTemperature: group.map(\.temperature).max() ?? 0, internalResistance: group.last { $0.internalResistance != nil }?.internalResistance))
            group = []
        }
        for s in samples {
            if let last = group.last, last.status != s.status { flush() }
            if kind(s.status) != nil { group.append(s) } else { flush() }
        }
        flush()
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.time.timeIntervalSince(a.time)
            if dt > gapThreshold { gap += dt; gaps += 1 }
        }
        let span = (samples.last?.time.timeIntervalSince(samples.first?.time ?? Date()) ?? 0)
        // Time the charger had already run before the first reading also counts as missing.
        let missedAtStart = Double(samples.first?.elapsed ?? 0)
        let total = span + missedAtStart
        return RunAnalysis(phases: phases, gapSeconds: gap, gapCount: gaps, coverage: total > 0 ? max(0, (span - gap)) / total : 1)
    }

    public static func downsample(_ s: [Sample], max n: Int) -> [Sample] {
        guard s.count > n, n > 2 else { return s }
        // Keeps the lowest-current reading in each bucket, so the charger's brief dips stay visible.
        let size = Double(s.count) / Double(n)
        return (0..<n).compactMap { i in
            let a = Int(Double(i) * size), b = min(s.count, Int(Double(i + 1) * size))
            guard a < b else { return nil }
            return s[a..<b].min { $0.milliamps < $1.milliamps }
        }
    }

    public static func csv(_ s: [Sample]) -> String {
        var o = "time,elapsed_s,cycle,status,voltage_mV,loaded_voltage_mV,current_mA,capacity_mAh,temperature_C,resistance_mOhm,energy_mWh,source\n"
        let f = ISO8601DateFormatter()
        for x in s {
            o += "\(f.string(from: x.time)),\(x.elapsed),\(x.cycle),\(x.status),\(x.millivolts),\(x.loadedMillivolts.map(String.init) ?? ""),\(x.milliamps),\(x.capacity),\(x.temperature),\(x.internalResistance.map(String.init) ?? ""),\(x.energy.map(String.init) ?? ""),\(x.source.rawValue)\n"
        }
        return o
    }

    public struct MatchCell: Equatable, Sendable { public let id: Int64; public let label: String; public let capacity: Double; public let resistance: Int?
        public init(id: Int64, label: String, capacity: Double, resistance: Int?) { self.id = id; self.label = label; self.capacity = capacity; self.resistance = resistance } }
    public struct Match: Equatable, Sendable { public let cells: [MatchCell]; public let capacitySpread: Double; public let resistanceSpread: Int?; public let limitedBy: MatchCell }

    /// Closest groups of `size` by capacity, then resistance. Sorted capacity means the tightest groups are always neighbors.
    public static func packMatches(_ cells: [MatchCell], size: Int, top: Int = 3) -> [Match] {
        guard size >= 2, cells.count >= size else { return [] }
        let sorted = cells.sorted { $0.capacity > $1.capacity }
        var out: [Match] = []
        for i in 0...(sorted.count - size) {
            let g = Array(sorted[i..<(i + size)])
            let irs = g.compactMap(\.resistance)
            out.append(Match(cells: g, capacitySpread: g.first!.capacity - g.last!.capacity, resistanceSpread: irs.count == g.count ? (irs.max()! - irs.min()!) : nil, limitedBy: g.last!))
        }
        return Array(out.sorted { ($0.capacitySpread, $0.resistanceSpread ?? Int.max) < ($1.capacitySpread, $1.resistanceSpread ?? Int.max) }.prefix(top))
    }

    public enum Health: String, Sendable { case good = "Good", watch = "Watch", weak = "Weak" }
    /// Placeholder cutoffs until you choose your own.
    public static func health(capacity: Double, rated: Int) -> Health {
        guard rated > 0 else { return .watch }
        let p = capacity / Double(rated)
        return p >= 0.9 ? .good : p >= 0.8 ? .watch : .weak
    }
}
