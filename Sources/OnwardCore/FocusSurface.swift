import Foundation

/// Surface identity excludes changing text, selection, and OCR results.
public struct FocusSurface: Equatable, Sendable {
    private let bundleID: String
    private let pid: Int32
    private let windowID: UInt32?
    private let titleFallback: String
    private let url: String
    private let browserTabID: String?
    private let activeWorkspace: String?

    public init(_ observation: Observation) {
        bundleID = observation.bundleID; pid = observation.pid
        windowID = observation.windowID; url = observation.url
        browserTabID = observation.browserTabID
        activeWorkspace = observation.activeWorkspace.map { [$0.project, $0.thread].joined(separator: "\u{1f}") }
        // Browser titles can change while the same page updates (unread counts, progress, etc.).
        // Without a stable tab ID, titles also distinguish reused documents or same-URL tabs.
        titleFallback = (url.isEmpty || browserTabID == nil) ? [observation.windowTitle, observation.tabTitle].joined(separator: "\u{1f}") : ""
    }

    /// FocusPolicy separately limits the age of the accepted judgment.
    public func canDisplayJudgment(for observation: Observation, foregroundPID: Int32?, at now: Date,
                                   maximumCaptureAge: TimeInterval = 12) -> Bool {
        let age = now.timeIntervalSince(observation.capturedAt)
        return self == FocusSurface(observation) && pid == foregroundPID && age >= 0 && age < maximumCaptureAge
    }
}
