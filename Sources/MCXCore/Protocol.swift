import Foundation

public enum BatteryType: UInt8, CaseIterable, Codable, Identifiable, Sendable {
    case liIon = 0, liFe = 1, li435 = 2, nimh = 3, nicd = 4, nizn = 5, eneloop = 6, ram = 7, lto = 8, naIon = 9
    public var id: UInt8 { rawValue }
    public var name: String {
        switch self {
        case .liIon: "Li-ion"
        case .liFe: "LiFePO4"
        case .li435: "Li-ion 4.35 V"
        case .nimh: "NiMH"
        case .nicd: "NiCd"
        case .nizn: "NiZn"
        case .eneloop: "Eneloop"
        case .ram: "RAM"
        case .lto: "LTO"
        case .naIon: "Na-ion"
        }
    }
    public var isNickel: Bool { self == .nimh || self == .nicd || self == .eneloop }
    public var isLithium: Bool { self == .liIon || self == .liFe || self == .li435 }
    /// Types the app can program. Others can still be monitored.
    public var canProgram: Bool { isNickel || isLithium }
}

public enum ChargeMode: UInt8, CaseIterable, Codable, Identifiable, Sendable {
    case charge = 0, refresh = 1, storageOrBreakIn = 2, discharge = 3, cycle = 4
    public var id: UInt8 { rawValue }
    public func name(for type: BatteryType?) -> String {
        switch self {
        case .charge: "Charge"
        case .refresh: "Refresh"
        case .storageOrBreakIn: (type?.isLithium ?? false) ? "Storage" : "Break-in"
        case .discharge: "Discharge"
        case .cycle: "Cycle"
        }
    }
    public var charges: Bool { self != .discharge }
    public var discharges: Bool { self != .charge }
}

public struct SlotStatus: Equatable, Hashable, Codable, Sendable {
    public let raw: UInt8
    public init(raw: UInt8) { self.raw = raw }
    public var isActive: Bool { raw == 1 || raw == 2 || raw == 3 }
    public var isFault: Bool { raw >= 128 }
    public var isDone: Bool { raw == 4 }
    public var isIdle: Bool { raw == 0 }
    public var label: String {
        switch raw {
        case 0: "Stand-by"
        case 1: "Charging"
        case 2: "Discharging"
        case 3: "Resting"
        case 4: "Done"
        case 128: "Input voltage too low"
        case 129: "Input voltage too high"
        case 130: "Measurement chip 1 error"
        case 131: "Measurement chip 2 error"
        case 132: "Connection broken"
        case 133: "Check voltage"
        case 134: "Capacity limit reached"
        case 135: "Time limit reached"
        case 136: "Charger too hot"
        case 137: "Battery too hot"
        case 138: "Short circuit"
        case 139: "Reverse polarity"
        default: "Error \(raw)"
        }
    }
    /// Limits the charger applied as designed, rather than something going wrong.
    public var isExpectedCutoff: Bool { raw == 134 || raw == 135 }
}

public enum DataSource: String, Codable, Sendable { case usb, bluetooth }

public struct SlotReading: Equatable, Sendable {
    public var slot: Int
    public var rawType: UInt8
    public var rawMode: UInt8
    public var cycle: Int
    public var status: SlotStatus
    public var elapsed: Int
    public var millivolts: Int
    /// USB only. A second voltage that moves smoothly while the main value steps around current dips. Its exact meaning is unconfirmed: it reads above the main value early in a charge and below it near the end.
    public var loadedMillivolts: Int?
    public var milliamps: Int
    public var capacity: Double
    public var temperature: Double
    public var internalResistance: Int?
    public var energyMilliwattHours: Int?
    public var powerMilliwatts: Int?
    public var chargerTemperature: Double?
    public var source: DataSource

    public var type: BatteryType? { BatteryType(rawValue: rawType) }
    public var mode: ChargeMode? { ChargeMode(rawValue: rawMode) }
    /// The charger keeps a stale resistance while idle, so it only counts during or just after a run.
    public var resistanceIsLive: Bool { status.isActive || status.isDone }
    public var hasCell: Bool { millivolts > 200 }

    public init(slot: Int, rawType: UInt8, rawMode: UInt8, cycle: Int, status: SlotStatus, elapsed: Int, millivolts: Int, loadedMillivolts: Int? = nil, milliamps: Int, capacity: Double, temperature: Double, internalResistance: Int?, energyMilliwattHours: Int? = nil, powerMilliwatts: Int? = nil, chargerTemperature: Double? = nil, source: DataSource) {
        self.slot = slot; self.rawType = rawType; self.rawMode = rawMode; self.cycle = cycle; self.status = status; self.elapsed = elapsed
        self.millivolts = millivolts; self.loadedMillivolts = loadedMillivolts; self.milliamps = milliamps; self.capacity = capacity
        self.temperature = temperature; self.internalResistance = internalResistance; self.energyMilliwattHours = energyMilliwattHours
        self.powerMilliwatts = powerMilliwatts; self.chargerTemperature = chargerTemperature; self.source = source
    }
}

/// A slot program, in the charger's units.
public struct Program: Equatable, Hashable, Codable, Sendable {
    public var type: BatteryType = .nimh
    public var mode: ChargeMode = .charge
    public var capacityLimit = 0
    public var chargeCurrent = 1000
    public var dischargeCurrent = 500
    public var chargeStopMillivolts = 1650
    public var dischargeStopMillivolts = 1000
    public var chargeEndCurrent = 50
    public var dischargeEndCurrent = 500
    public var cycles = 1
    public var chargeRestMinutes = 0
    public var cycleMode = 0
    public var negativeDeltaMillivolts = 3
    public var trickleUnits = 0
    public var keepMillivolts = 1000
    public var temperatureCutoff = 45
    public var timeLimitMinutes = 120
    public var dischargeRestMinutes = 0

    public init() {}

    /// Bluetooth write (opcode 0x11): 40 bytes, sent as two 20-byte chunks. Voltage and rest fields sit in a different order from USB.
    public func bluetoothFrame(slot: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 40)
        func put(_ i: Int, _ v: Int) { b[i] = UInt8((v >> 8) & 255); b[i + 1] = UInt8(v & 255) }
        b[0] = 0x0F; b[1] = 0x11; b[2] = UInt8(1 << slot); b[3] = type.rawValue; b[4] = mode.rawValue
        put(5, capacityLimit); put(7, chargeCurrent); put(9, dischargeCurrent)
        put(11, chargeStopMillivolts); put(13, dischargeStopMillivolts)
        put(15, chargeEndCurrent); put(17, dischargeEndCurrent)
        b[19] = UInt8(chargeRestMinutes); b[20] = UInt8(cycles); b[21] = UInt8(cycleMode)
        b[22] = UInt8(negativeDeltaMillivolts); b[23] = UInt8(trickleUnits)
        put(24, keepMillivolts); b[26] = UInt8(temperatureCutoff); put(27, timeLimitMinutes); b[29] = UInt8(dischargeRestMinutes)
        b[39] = Wire.checksum(b[0..<39])
        return b
    }

    /// USB write (command 0x11): 36 bytes inside a 64-byte report.
    public func usbFrame(slot: Int, trickleTime: UInt8 = 0) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 36)
        func put(_ i: Int, _ v: Int) { f[i] = UInt8((v >> 8) & 255); f[i + 1] = UInt8(v & 255) }
        f[0] = 0x0F; f[1] = 0x20; f[2] = 0x11; f[4] = UInt8(slot); f[5] = type.rawValue
        put(6, capacityLimit); f[8] = mode.rawValue
        put(9, chargeCurrent); put(11, dischargeCurrent); put(13, dischargeStopMillivolts); put(15, chargeStopMillivolts)
        put(17, chargeEndCurrent); put(19, dischargeEndCurrent)
        f[21] = UInt8(cycles); f[22] = UInt8(chargeRestMinutes); f[23] = UInt8(dischargeRestMinutes); f[24] = UInt8(cycleMode)
        f[25] = UInt8(negativeDeltaMillivolts); f[26] = UInt8(trickleUnits); f[27] = trickleTime
        f[28] = UInt8(temperatureCutoff); put(29, timeLimitMinutes); put(31, keepMillivolts)
        f[33] = Wire.checksum(f[2..<33]); f[34] = 0xFF; f[35] = 0xFF
        return f
    }

    /// Decodes a USB slot-program reply (0x5F).
    public init?(usbReply r: [UInt8]) {
        guard r.count >= 32, r[0] == 0x5F, let t = BatteryType(rawValue: r[3]), let m = ChargeMode(rawValue: r[4]) else { return nil }
        func u(_ i: Int) -> Int { Int(r[i]) << 8 | Int(r[i + 1]) }
        type = t; mode = m; capacityLimit = u(5); chargeCurrent = u(7); dischargeCurrent = u(9)
        dischargeStopMillivolts = u(11); chargeStopMillivolts = u(13); chargeEndCurrent = u(15); dischargeEndCurrent = u(17)
        cycles = Int(r[19]); chargeRestMinutes = Int(r[20]); cycleMode = Int(r[21]); negativeDeltaMillivolts = Int(r[22]); trickleUnits = Int(r[23])
        keepMillivolts = u(24); temperatureCutoff = Int(r[26]); timeLimitMinutes = u(27); dischargeRestMinutes = Int(r[31])
    }

    /// Every field, labeled for the check-before-start screen.
    public var fields: [(name: String, value: String)] {
        [("Type", type.name), ("Mode", mode.name(for: type)),
         ("Capacity limit", capacityLimit == 0 ? "Off" : "\(capacityLimit) mAh"),
         ("Charge current", "\(chargeCurrent) mA"), ("Discharge current", "\(dischargeCurrent) mA"),
         ("Charge stop", Format.volts(chargeStopMillivolts)), ("Discharge stop", Format.volts(dischargeStopMillivolts)),
         ("Charge end current", "\(chargeEndCurrent) mA"), ("Discharge end current", "\(dischargeEndCurrent) mA"),
         ("Cycles", "\(cycles)"), ("Rest after charge", "\(chargeRestMinutes) min"), ("Cycle order", "\(cycleMode)"),
         ("-dV", "\(negativeDeltaMillivolts) mV"), ("Trickle", "\(trickleUnits * 10) mA"), ("Keep voltage", Format.volts(keepMillivolts)),
         ("Temperature cutoff", "\(temperatureCutoff) °C"), ("Time limit", timeLimitMinutes == 0 ? "Off" : "\(timeLimitMinutes) min"),
         ("Rest after discharge", "\(dischargeRestMinutes) min")]
    }
}

public enum Format {
    public static func volts(_ mV: Int) -> String { String(format: "%.3f V", Double(mV) / 1000) }
    public static func clock(_ s: Int) -> String { String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
}

/// Frame builders and parsers. Only the operations below can be built, so factory reset,
/// calibration restore and firmware update commands cannot be sent by this app.
public enum Wire {
    public static func checksum<S: Sequence>(_ b: S) -> UInt8 where S.Element == UInt8 { UInt8(b.reduce(0) { ($0 + Int($1)) & 255 }) }

    private static func ble(_ op: UInt8, _ args: [UInt8] = []) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20)
        b[0] = 0x0F; b[1] = op
        for (i, a) in args.enumerated() { b[2 + i] = a }
        b[19] = checksum(b[0..<19])
        return b
    }
    public static func bleStatus(slot: Int) -> [UInt8] { ble(0x55, [UInt8(slot)]) }
    public static func bleVersion() -> [UInt8] { ble(0x57) }
    public static func bleCurve(slot: Int) -> [UInt8] { ble(0x56, [UInt8(slot)]) }
    public static func bleStart(slot: Int) -> [UInt8] { ble(0x05, [UInt8(1 << slot)]) }
    public static func bleStop(slot: Int) -> [UInt8] { ble(0xFE, [UInt8(1 << slot)]) }
    /// Mask 15, as SkyRC's app sends it. Tested on firmware 1.27: stopped three running slots in under a second.
    public static let bleStopAll: [UInt8] = ble(0xFE, [0x0F])
    public static func isAck(_ r: [UInt8], op: UInt8, slot: Int) -> Bool { r.count == 20 && r[1] == op && r[2] == UInt8(1 << slot) && r[3] == 0xF0 }

    public static func usbLive(slot: Int) -> [UInt8] { [0x0F, 0x04, 0x55, 0x00, UInt8(slot), 0x55 &+ UInt8(slot), 0xFF, 0xFF] }
    public static func usbProgram(slot: Int) -> [UInt8] { [0x0F, 0x04, 0x5F, 0x00, UInt8(slot), 0x5F &+ UInt8(slot), 0xFF, 0xFF] }
    public static let usbSystem: [UInt8] = [0x0F, 0x04, 0x5A, 0x00, 0x00, 0x5A, 0xFF, 0xFF]
    /// Global: starts every loaded slot. USB has no per-slot start.
    public static let usbStartAll: [UInt8] = [0x0F, 0x03, 0x05, 0x00, 0x05, 0xFF, 0xFF]
    /// Global: stops every slot. USB has no per-slot stop.
    public static let usbStopAll: [UInt8] = [0x0F, 0x03, 0xFE, 0x00, 0xFE, 0xFF, 0xFF]

    public static func parseBluetoothStatus(_ b: [UInt8]) -> SlotReading? {
        guard b.count == 20, b[0] == 0x0F, b[1] == 0x55, checksum(b[0..<19]) == b[19], b[2] < 4 else { return nil }
        func u(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        let ir = u(16)
        return SlotReading(slot: Int(b[2]), rawType: b[3], rawMode: b[4], cycle: Int(b[5]), status: SlotStatus(raw: b[6]), elapsed: u(7), millivolts: u(9), milliamps: u(11), capacity: Double(u(13)), temperature: Double(b[15]), internalResistance: (ir == 0 || ir == 1 || ir == 0xFFFF) ? nil : ir, source: .bluetooth)
    }

    public static func parseUSBLive(_ r: [UInt8]) -> SlotReading? {
        guard r.count == 64, r[0] == 0x55, checksum(r[0..<63]) == r[63], r[1] < 4 else { return nil }
        func u(_ i: Int) -> Int { Int(r[i]) << 8 | Int(r[i + 1]) }
        let ir = u(16), loaded = u(25)
        return SlotReading(slot: Int(r[1]), rawType: r[2], rawMode: r[3], cycle: Int(r[4]), status: SlotStatus(raw: r[5]), elapsed: u(6), millivolts: u(8), loadedMillivolts: loaded == 0 ? nil : loaded, milliamps: u(10), capacity: Double(u(12)) + Double(r[24]) / 10, temperature: Double(u(14)) / 10, internalResistance: (ir == 0 || ir == 1 || ir == 0xFFFF) ? nil : ir, energyMilliwattHours: u(20), powerMilliwatts: u(22), chargerTemperature: Double(u(18)) / 10, source: .usb)
    }

    public struct Version: Equatable, Sendable {
        public let firmware: String; public let hardware: String; public let machineID: String
        /// The ID every MC3000 seen so far reports. Program and start frames are MC3000-specific; other models use different commands.
        public static let mc3000ID = "100083"
        public var isMC3000: Bool { machineID == Self.mc3000ID }
    }
    private static func ascii(_ b: ArraySlice<UInt8>) -> String { String(decoding: b, as: UTF8.self) }
    /// Bluetooth version replies have a bad checksum on real chargers, so it is not checked.
    public static func parseBluetoothVersion(_ b: [UInt8]) -> Version? {
        guard b.count == 20, b[1] == 0x57 else { return nil }
        return Version(firmware: String(format: "%d.%02d", b[14], b[15]), hardware: String(format: "%d.%d", b[16] / 10, b[16] % 10), machineID: ascii(b[3...8]))
    }
    public static func parseUSBVersion(_ r: [UInt8]) -> Version? {
        guard r.count >= 30, r[0] == 0x5A else { return nil }
        return Version(firmware: String(format: "%d.%02d", r[27], r[28]), hardware: String(format: "%d.%d", r[29] / 10, r[29] % 10), machineID: ascii(r[16...21]))
    }
}
