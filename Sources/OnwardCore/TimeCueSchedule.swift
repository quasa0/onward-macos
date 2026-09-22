import Foundation

public enum TimeCueInterval: Int, CaseIterable, Identifiable, Sendable {
    case fiveSeconds = 5
    case tenSeconds = 10
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case oneMinute = 60

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }
}

/// A one-shot wall-clock schedule. The owner arms a timer for `nextFireDate`,
/// calls `consume(at:)`, then arms the updated date. Missed cues are discarded.
public struct TimeCueSchedule: Sendable {
    public let interval: TimeCueInterval
    public private(set) var nextFireDate: Date
    private var lastObservedAt: Date

    public init(interval: TimeCueInterval, now: Date) {
        self.interval = interval
        nextFireDate = Self.nextBoundary(after: now, interval: interval)
        lastObservedAt = now
    }

    /// All presets divide a minute, so epoch alignment also aligns local clock
    /// seconds. An exact boundary advances to the following one.
    public static func nextBoundary(after date: Date, interval: TimeCueInterval) -> Date {
        let next = (floor(date.timeIntervalSince1970 / interval.seconds) + 1) * interval.seconds
        return Date(timeIntervalSince1970: next)
    }

    /// Allows ordinary timer lateness up to half a second, never an early cue.
    /// A backward clock change starts a new clock sequence without an immediate
    /// cue. A late callback skips directly to the next future boundary.
    public mutating func consume(at now: Date) -> Bool {
        defer { lastObservedAt = now }
        if now < lastObservedAt {
            nextFireDate = Self.nextBoundary(after: now, interval: interval)
            return false
        }
        guard now >= nextFireDate else { return false }
        let shouldFire = now.timeIntervalSince(nextFireDate) <= 0.5
        nextFireDate = Self.nextBoundary(after: now, interval: interval)
        return shouldFire
    }
}
