import Foundation

/// Monotonic cadence follows the visible red state, including retained red during checking.
public struct DistractionReminder: Sendable {
    public enum Cue: Equatable, Sendable { case enteredRed, repeated }
    private let intervalRange: ClosedRange<Int>
    public private(set) var nextReminderAt: TimeInterval?

    public init(intervalRange: ClosedRange<Int> = 3...7) {
        precondition(intervalRange.lowerBound > 0)
        self.intervalRange = intervalRange
    }
    public mutating func reset() { nextReminderAt = nil }

    public mutating func cue(isRedVisible: Bool, at uptime: TimeInterval) -> Cue? {
        guard isRedVisible, uptime.isFinite, uptime >= 0 else { reset(); return nil }
        if let nextReminderAt, uptime < nextReminderAt { return nil }
        let cue: Cue = nextReminderAt == nil ? .enteredRed : .repeated
        // Choose once per warning. A late callback sends one cue, never a catch-up burst.
        nextReminderAt = uptime + Double(Int.random(in: intervalRange))
        return cue
    }
}
