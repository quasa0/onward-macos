import Foundation

/// Measures repeat reminders in confirmed off-goal time, so checking cannot advance them.
public struct DistractionReminder: Sendable {
    public let interval: TimeInterval
    private var lastReminderElapsed: TimeInterval?
    private var episodeStartedAt: Date?

    public init(interval: TimeInterval = 30) { self.interval = max(1, interval) }
    public mutating func reset() { lastReminderElapsed = nil; episodeStartedAt = nil }

    public mutating func shouldRemind(status: FocusStatus, confirmedSeconds: TimeInterval,
                                     holdingStatus: Bool = false, episodeStartedAt: Date? = nil) -> Bool {
        guard !holdingStatus else { return false }
        if self.episodeStartedAt != episodeStartedAt {
            lastReminderElapsed = nil
            self.episodeStartedAt = episodeStartedAt
        }
        if status == .focused || status == .ready { reset(); return false }
        guard status == .distracted, confirmedSeconds.isFinite, confirmedSeconds >= 0 else { return false }
        if let last = lastReminderElapsed, confirmedSeconds >= last,
           confirmedSeconds - last < interval { return false }
        lastReminderElapsed = confirmedSeconds
        return true
    }
}
