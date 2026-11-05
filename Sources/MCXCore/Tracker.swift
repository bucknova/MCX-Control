import Foundation

/// Turns the reading stream for one slot into runs. Pure logic, so it can be tested against recorded data.
public struct RunTracker: Sendable {
    public enum Event: Equatable, Sendable {
        case started(joined: Bool)
        case resumed
        case sample
        case ended(status: SlotStatus, reason: EndReason)
    }
    public enum EndReason: String, Codable, Sendable { case finished, limit, fault, stopped }

    public struct OpenRun: Equatable, Sendable { public var type: UInt8; public var mode: UInt8; public var lastElapsed: Int; public init(type: UInt8, mode: UInt8, lastElapsed: Int) { self.type = type; self.mode = mode; self.lastElapsed = lastElapsed } }

    public private(set) var open: OpenRun?
    private var idleStreak = 0
    private var faultStreak = 0
    /// A status has to hold this long to end a run; a brief 133 has been seen at charge start.
    static let debounce = 5

    public init(resuming: OpenRun? = nil) { open = resuming }

    public mutating func ingest(_ r: SlotReading) -> [Event] {
        if r.status.isActive {
            idleStreak = 0; faultStreak = 0
            if let o = open {
                // Timer going backwards with the same type and mode means a new run in single-phase modes.
                let multi = o.mode == ChargeMode.refresh.rawValue || o.mode == ChargeMode.cycle.rawValue || o.mode == ChargeMode.storageOrBreakIn.rawValue
                if o.type != r.rawType || o.mode != r.rawMode || (!multi && r.elapsed + 5 < o.lastElapsed) {
                    open = OpenRun(type: r.rawType, mode: r.rawMode, lastElapsed: r.elapsed)
                    return [.ended(status: SlotStatus(raw: 0), reason: .stopped), .started(joined: r.elapsed > 5), .sample]
                }
                open?.lastElapsed = r.elapsed
                return [.sample]
            }
            open = OpenRun(type: r.rawType, mode: r.rawMode, lastElapsed: r.elapsed)
            return [.started(joined: r.elapsed > 5), .sample]
        }
        guard open != nil else { return [] }
        if r.status.isDone {
            open = nil
            return [.sample, .ended(status: r.status, reason: .finished)]
        }
        if r.status.isFault {
            faultStreak += 1
            guard faultStreak >= Self.debounce else { return [.sample] }
            open = nil
            return [.ended(status: r.status, reason: r.status.isExpectedCutoff ? .limit : .fault)]
        }
        idleStreak += 1
        guard idleStreak >= Self.debounce else { return [] }
        open = nil
        return [.ended(status: r.status, reason: .stopped)]
    }
}
