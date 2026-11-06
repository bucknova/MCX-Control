import Foundation
import SQLite3

public struct Cell: Identifiable, Equatable, Sendable, Hashable {
    public var id: Int64; public var label: String; public var type: BatteryType; public var rated: Int; public var notes: String
    public init(id: Int64 = 0, label: String, type: BatteryType, rated: Int, notes: String = "") { self.id = id; self.label = label; self.type = type; self.rated = rated; self.notes = notes }
}

public struct RunRecord: Identifiable, Equatable, Sendable, Hashable {
    public var id: Int64; public var slot: Int; public var cellID: Int64?; public var rawType: UInt8; public var rawMode: UInt8; public var program: Program?
    public var started: Date; public var ended: Date?; public var endStatus: UInt8?; public var endReason: String?; public var joinedAt: Int
    public var chargeCapacity: Double?; public var dischargeCapacity: Double?; public var chargeEnergy: Double?; public var dischargeEnergy: Double?; public var resistance: Int?; public var coverage: Double?; public var gapSeconds: Double?
    /// Set when a run is recorded as stopped. Runs saved before this was tracked have none.
    public var stop: StopRecord?
    public var type: BatteryType? { BatteryType(rawValue: rawType) }
    public var mode: ChargeMode? { ChargeMode(rawValue: rawMode) }
}

public struct NamedProgram: Identifiable, Equatable, Sendable { public var name: String; public var rated: Int; public var program: Program; public var id: String { name }
    public init(name: String, rated: Int, program: Program) { self.name = name; self.rated = rated; self.program = program } }

/// SQLite on the main thread: at most a few short inserts per second.
public final class Store {
    private var db: OpaquePointer?
    /// Called when a write fails, so a full disk can't quietly lose a test.
    public var onError: ((String) -> Void)?
    private let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        if path != ":memory:" { try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true) }
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "Store", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't open the database at \(path)"]) }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        try exec("""
        CREATE TABLE IF NOT EXISTS cells(id INTEGER PRIMARY KEY, label TEXT NOT NULL UNIQUE, type INTEGER NOT NULL, rated INTEGER NOT NULL, notes TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS runs(id INTEGER PRIMARY KEY, slot INTEGER NOT NULL, cell_id INTEGER REFERENCES cells(id) ON DELETE SET NULL, type INTEGER NOT NULL, mode INTEGER NOT NULL, program TEXT, started REAL NOT NULL, ended REAL, end_status INTEGER, end_reason TEXT, joined_at INTEGER NOT NULL DEFAULT 0, charge_cap REAL, discharge_cap REAL, charge_wh REAL, discharge_wh REAL, ir INTEGER, coverage REAL, gap_s REAL);
        CREATE TABLE IF NOT EXISTS samples(run_id INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE, time REAL NOT NULL, cycle INTEGER, status INTEGER, elapsed INTEGER, mv INTEGER, loaded_mv INTEGER, ma INTEGER, cap REAL, temp REAL, ir INTEGER, energy INTEGER, source TEXT);
        CREATE INDEX IF NOT EXISTS samples_run ON samples(run_id, time);
        CREATE TABLE IF NOT EXISTS presets(name TEXT PRIMARY KEY, rated INTEGER NOT NULL, program TEXT NOT NULL);
        """)
        var columns = Set<String>()
        run("PRAGMA table_info(runs)") { columns.insert(self.optText($0, 1) ?? "") }
        for (name, kind) in [("stop_source", "TEXT"), ("stop_requested", "REAL")] where !columns.contains(name) { try exec("ALTER TABLE runs ADD COLUMN \(name) \(kind)") }
    }
    deinit { sqlite3_close(db) }

    private func exec(_ s: String) throws { if sqlite3_exec(db, s, nil, nil, nil) != SQLITE_OK { throw NSError(domain: "Store", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]) } }
    private enum V { case i(Int64), d(Double), s(String), null }
    private func v(_ x: Int?) -> V { x.map { .i(Int64($0)) } ?? .null }
    private func v(_ x: Double?) -> V { x.map { .d($0) } ?? .null }
    private func v(_ x: Int64?) -> V { x.map { .i($0) } ?? .null }
    private func v(_ x: String?) -> V { x.map { .s($0) } ?? .null }
    @discardableResult private func run(_ sql: String, _ args: [V] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { onError?(String(cString: sqlite3_errmsg(db))); return false }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .i(let x): sqlite3_bind_int64(st, n, x)
            case .d(let x): sqlite3_bind_double(st, n, x)
            case .s(let x): sqlite3_bind_text(st, n, x, -1, T)
            case .null: sqlite3_bind_null(st, n)
            }
        }
        while true {
            let r = sqlite3_step(st)
            if r == SQLITE_ROW { row?(st); continue }
            if r != SQLITE_DONE { onError?(String(cString: sqlite3_errmsg(db))) }
            return r == SQLITE_DONE
        }
    }
    private func optInt(_ st: OpaquePointer, _ i: Int32) -> Int? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, i)) }
    private func optDouble(_ st: OpaquePointer, _ i: Int32) -> Double? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i) }
    private func optText(_ st: OpaquePointer, _ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
    private func json(_ p: Program?) -> String? { p.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } }
    private func program(_ s: String?) -> Program? { s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Program.self, from: $0) } }

    // MARK: Cells
    public func cells() -> [Cell] {
        var o: [Cell] = []
        run("SELECT id,label,type,rated,notes FROM cells ORDER BY label COLLATE NOCASE") { st in
            o.append(Cell(id: sqlite3_column_int64(st, 0), label: self.optText(st, 1) ?? "", type: BatteryType(rawValue: UInt8(sqlite3_column_int(st, 2))) ?? .nimh, rated: Int(sqlite3_column_int(st, 3)), notes: self.optText(st, 4) ?? ""))
        }
        return o
    }
    @discardableResult public func save(_ c: Cell) -> Bool {
        c.id == 0 ? run("INSERT INTO cells(label,type,rated,notes) VALUES(?,?,?,?)", [.s(c.label), .i(Int64(c.type.rawValue)), .i(Int64(c.rated)), .s(c.notes)])
                  : run("UPDATE cells SET label=?,type=?,rated=?,notes=? WHERE id=?", [.s(c.label), .i(Int64(c.type.rawValue)), .i(Int64(c.rated)), .s(c.notes), .i(c.id)])
    }
    public func delete(cell id: Int64) { run("DELETE FROM cells WHERE id=?", [.i(id)]) }

    // MARK: Runs
    public func createRun(slot: Int, cellID: Int64?, type: UInt8, mode: UInt8, program p: Program?, started: Date, joinedAt: Int) -> Int64? {
        let ok = run("INSERT INTO runs(slot,cell_id,type,mode,program,started,joined_at) VALUES(?,?,?,?,?,?,?)", [.i(Int64(slot)), v(cellID), .i(Int64(type)), .i(Int64(mode)), v(json(p)), .d(started.timeIntervalSince1970), .i(Int64(joinedAt))])
        return ok ? sqlite3_last_insert_rowid(db) : nil
    }
    public func append(run id: Int64, _ s: Sample) {
        run("INSERT INTO samples VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", [.i(id), .d(s.time.timeIntervalSince1970), .i(Int64(s.cycle)), .i(Int64(s.status)), .i(Int64(s.elapsed)), .i(Int64(s.millivolts)), v(s.loadedMillivolts), .i(Int64(s.milliamps)), .d(s.capacity), .d(s.temperature), v(s.internalResistance), v(s.energy), .s(s.source.rawValue)])
    }
    /// Saved as the command goes out, so it survives the app quitting before the charger's response is seen.
    public func noteStop(run id: Int64, _ s: StopRecord) { run("UPDATE runs SET stop_source=?,stop_requested=? WHERE id=?", [.s(s.source.rawValue), v(s.time?.timeIntervalSince1970), .i(id)]) }
    public func finish(run id: Int64, status: UInt8, reason: String, at: Date, analysis a: RunAnalysis, stop: StopRecord? = nil) {
        run("UPDATE runs SET ended=?,end_status=?,end_reason=?,charge_cap=?,discharge_cap=?,charge_wh=?,discharge_wh=?,ir=?,coverage=?,gap_s=?,stop_source=?,stop_requested=? WHERE id=?", [.d(at.timeIntervalSince1970), .i(Int64(status)), .s(reason), .d(a.chargeCapacity), v(a.dischargeCapacity), .d(a.chargeEnergy), .d(a.dischargeEnergy), v(a.internalResistance), .d(a.coverage), .d(a.gapSeconds), v(stop?.source.rawValue), v(stop?.time?.timeIntervalSince1970), .i(id)])
    }
    public func assign(run id: Int64, cell: Int64?) { run("UPDATE runs SET cell_id=? WHERE id=?", [v(cell), .i(id)]) }
    public func delete(run id: Int64) { run("DELETE FROM runs WHERE id=?", [.i(id)]) }
    private let runColumns = "id,slot,cell_id,type,mode,program,started,ended,end_status,end_reason,joined_at,charge_cap,discharge_cap,charge_wh,discharge_wh,ir,coverage,gap_s,stop_source,stop_requested"
    private func runRow(_ st: OpaquePointer) -> RunRecord {
        RunRecord(id: sqlite3_column_int64(st, 0), slot: Int(sqlite3_column_int(st, 1)), cellID: optInt(st, 2).map(Int64.init), rawType: UInt8(sqlite3_column_int(st, 3)), rawMode: UInt8(sqlite3_column_int(st, 4)), program: program(optText(st, 5)), started: Date(timeIntervalSince1970: sqlite3_column_double(st, 6)), ended: optDouble(st, 7).map { Date(timeIntervalSince1970: $0) }, endStatus: optInt(st, 8).map { UInt8($0) }, endReason: optText(st, 9), joinedAt: Int(sqlite3_column_int(st, 10)), chargeCapacity: optDouble(st, 11), dischargeCapacity: optDouble(st, 12), chargeEnergy: optDouble(st, 13), dischargeEnergy: optDouble(st, 14), resistance: optInt(st, 15), coverage: optDouble(st, 16), gapSeconds: optDouble(st, 17), stop: optText(st, 18).flatMap(StopSource.init(rawValue:)).map { StopRecord(source: $0, time: optDouble(st, 19).map { Date(timeIntervalSince1970: $0) }) })
    }
    public func runs(limit: Int = 500) -> [RunRecord] {
        var o: [RunRecord] = []; run("SELECT \(runColumns) FROM runs ORDER BY started DESC LIMIT ?", [.i(Int64(limit))]) { o.append(self.runRow($0)) }; return o
    }
    public func runs(cell: Int64) -> [RunRecord] {
        var o: [RunRecord] = []; run("SELECT \(runColumns) FROM runs WHERE cell_id=? AND ended IS NOT NULL ORDER BY started", [.i(cell)]) { o.append(self.runRow($0)) }; return o
    }
    public func openRun(slot: Int) -> RunRecord? {
        var o: RunRecord?; run("SELECT \(runColumns) FROM runs WHERE slot=? AND ended IS NULL ORDER BY started DESC LIMIT 1", [.i(Int64(slot))]) { o = self.runRow($0) }; return o
    }
    public func samples(run id: Int64) -> [Sample] {
        var o: [Sample] = []
        run("SELECT time,cycle,status,elapsed,mv,loaded_mv,ma,cap,temp,ir,energy,source FROM samples WHERE run_id=? ORDER BY time", [.i(id)]) { st in
            o.append(Sample(time: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)), cycle: Int(sqlite3_column_int(st, 1)), status: UInt8(sqlite3_column_int(st, 2)), elapsed: Int(sqlite3_column_int(st, 3)), millivolts: Int(sqlite3_column_int(st, 4)), loadedMillivolts: self.optInt(st, 5), milliamps: Int(sqlite3_column_int(st, 6)), capacity: sqlite3_column_double(st, 7), temperature: sqlite3_column_double(st, 8), internalResistance: self.optInt(st, 9), energy: self.optInt(st, 10), source: DataSource(rawValue: self.optText(st, 11) ?? "") ?? .usb))
        }
        return o
    }

    // MARK: Presets
    public func presets() -> [NamedProgram] {
        var o: [NamedProgram] = []
        run("SELECT name,rated,program FROM presets ORDER BY name COLLATE NOCASE") { st in if let p = self.program(self.optText(st, 2)) { o.append(NamedProgram(name: self.optText(st, 0) ?? "", rated: Int(sqlite3_column_int(st, 1)), program: p)) } }
        return o
    }
    public func save(preset n: NamedProgram) { run("INSERT OR REPLACE INTO presets VALUES(?,?,?)", [.s(n.name), .i(Int64(n.rated)), v(json(n.program))]) }
}
