import AppKit
import Foundation
import OnwardCore

/// Emits cues on wall-clock boundaries. The owner supplies sound and session policy.
@MainActor
final class TimeCueController {
    var onCue: () -> Void

    private var enabled = false
    private var suspended = false
    private var interval: TimeCueInterval = .oneMinute
    private var schedule: TimeCueSchedule?
    private var timer: Timer?
    private var clockObserver: NSObjectProtocol?
    private var timingActivity: NSObjectProtocol?
    private var generation = UUID()

    init(onCue: @escaping () -> Void = {}) {
        self.onCue = onCue
    }

    func configure(enabled: Bool, interval: TimeCueInterval) {
        let changed = self.enabled != enabled || self.interval != interval
        self.enabled = enabled
        self.interval = interval
        guard enabled else { stop(); return }
        observeClockIfNeeded()
        guard changed || schedule == nil else { return }
        reanchor()
    }

    func setSuspended(_ suspended: Bool) {
        guard self.suspended != suspended else { return }
        self.suspended = suspended
        reanchor()
    }

    func stop() {
        enabled = false
        invalidateTimer()
        schedule = nil
        updateTimingActivity()
        if let clockObserver {
            NotificationCenter.default.removeObserver(clockObserver)
            self.clockObserver = nil
        }
    }

    private func observeClockIfNeeded() {
        guard clockObserver == nil else { return }
        clockObserver = NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reanchor() }
        }
    }

    private func reanchor() {
        invalidateTimer()
        schedule = nil
        updateTimingActivity()
        guard enabled, !suspended else { return }
        schedule = TimeCueSchedule(interval: interval, now: Date())
        arm()
    }

    private func updateTimingActivity() {
        if enabled, !suspended {
            guard timingActivity == nil else { return }
            // Keep background timers out of App Nap without preventing idle sleep.
            timingActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Keep user-enabled time cues aligned to the clock"
            )
        } else if let timingActivity {
            ProcessInfo.processInfo.endActivity(timingActivity)
            self.timingActivity = nil
        }
    }

    private func invalidateTimer() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
    }

    private func arm() {
        invalidateTimer()
        guard enabled, !suspended, var schedule else { return }
        let now = Date()
        // A slow callback must not leave an already-expired timer to replay later.
        if schedule.nextFireDate <= now {
            schedule = TimeCueSchedule(interval: interval, now: now)
            self.schedule = schedule
        }
        let expectedGeneration = generation
        let timer = Timer(fire: schedule.nextFireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire(expectedGeneration: expectedGeneration) }
        }
        timer.tolerance = 0
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func fire(expectedGeneration: UUID) {
        guard generation == expectedGeneration, enabled, !suspended, var schedule else { return }
        timer = nil
        let shouldEmit = schedule.consume(at: Date())
        self.schedule = schedule
        // Also cover a lock that occurs before the owner's session notification arrives.
        if shouldEmit, let foreground = NSWorkspace.shared.frontmostApplication,
           foreground.bundleIdentifier != "com.apple.loginwindow" {
            onCue()
        }
        // The callback can disable, suspend, or reconfigure its owner synchronously.
        guard generation == expectedGeneration, enabled, !suspended else { return }
        arm()
    }

    deinit {
        timer?.invalidate()
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
        if let timingActivity { ProcessInfo.processInfo.endActivity(timingActivity) }
    }
}
