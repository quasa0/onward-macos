import Foundation
import CryptoKit

public struct Observation: Codable, Equatable, Sendable {
    public var id = UUID()
    public var capturedAt = Date()
    public var appName = ""
    public var bundleID = ""
    public var pid: Int32 = 0
    public var windowTitle = ""
    public var windowID: UInt32?
    public var tabTitle = ""
    public var browserTabID: String?
    public var url = ""
    public var focusedElement = ""
    public var selectedText = ""
    public var accessibilityText = ""
    public var browserText = ""
    public var ocrText = ""
    public var activeWorkspace: ActiveWorkspaceEvidence?
    public var ocrLayout: OCRLayoutEvidence?
    public var sources: [String] = []
    public var warnings: [String] = []
    public var idleSeconds: Double = 0
    public var captureMilliseconds: Int = 0
    public init() {}

    public var fingerprint: String {
        let text = [bundleID, String(pid), String(windowID ?? 0), windowTitle, tabTitle, browserTabID ?? "", url,
                    activeWorkspace?.project ?? "", activeWorkspace?.thread ?? "", activeWorkspace?.source ?? "",
                    focusedElement, selectedText, accessibilityText, browserText, ocrText].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var summary: String {
        [appName, tabTitle.isEmpty ? windowTitle : tabTitle, url].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    public var hasEvidence: Bool {
        ![windowTitle, tabTitle, url, accessibilityText, browserText, ocrText].allSatisfy { $0.isEmpty }
    }
    public var textCount: Int { accessibilityText.count + browserText.count + ocrText.count + selectedText.count }
}

// Adapted from OpenAI Codex take_bytes_at_char_boundary, Apache-2.0.
// Source commit d583e73c4d1204f1e9f654ef87065e9f0dd07ac7,
// codex-rs/utils/string/src/lib.rs. See THIRD_PARTY_NOTICES.md.
public func boundedText(_ text: String, bytes: Int) -> String {
    guard text.utf8.count > bytes else { return text }
    var result = ""
    var used = 0
    for scalar in text.unicodeScalars {
        let count = scalar.utf8.count
        if used + count > max(0, bytes) { break }
        result.unicodeScalars.append(scalar)
        used += count
    }
    return result
}

public enum Alignment: String, Codable, CaseIterable, Sendable {
    case onGoal = "on_goal", supporting, offGoal = "off_goal", unclear
    public var label: String {
        switch self {
        case .onGoal: return "On course"
        case .supporting: return "Supporting your goal"
        case .offGoal: return "Off course"
        case .unclear: return "Needs context"
        }
    }
}

public struct Judgment: Codable, Equatable, Sendable {
    public let alignment: Alignment
    public let probabilities: [String: Double]
    public let confidence: Double
    public let activity: String
    public let model: String
    public let inputTokens: Int
    public let latencyMilliseconds: Int
    public var probability: Double { probabilities[alignment.rawValue] ?? 0 }
    public init(alignment: Alignment, probabilities: [String: Double], confidence: Double,
                activity: String = "unknown", model: String = "test", inputTokens: Int = 0, latencyMilliseconds: Int = 0) {
        self.alignment = alignment; self.probabilities = probabilities; self.confidence = confidence
        self.activity = activity; self.model = model; self.inputTokens = inputTokens; self.latencyMilliseconds = latencyMilliseconds
    }
}

public enum FocusStatus: String, Sendable {
    case ready, observing, focused, drifting, distracted, unclear, paused, idle, unavailable
    public var title: String {
        switch self {
        case .ready: return "Choose your direction"
        case .observing: return "Reading the moment"
        case .focused: return "You're on course"
        case .drifting: return "You're drifting"
        case .distracted: return "Come back to your goal"
        case .unclear: return "A little more context"
        case .paused: return "Take your time"
        case .idle: return "Away from your Mac"
        case .unavailable: return "Observer needs attention"
        }
    }
}

public struct FocusPolicy: Sendable {
    public var redAfter: TimeInterval = 45
    public var maximumEvidenceAge: TimeInterval = 30
    public private(set) var offGoalSince: Date?
    public private(set) var lastJudgmentAt: Date?
    public private(set) var alignment: Alignment = .unclear
    public var isHoldingStatus: Bool { alignment == .unclear && heldStatus != nil }
    private var heldStatus: FocusStatus?
    private var uncertaintyStartedAt: Date?
    private var uncertainDuration: TimeInterval = 0
    public init() {}
    public mutating func reset() {
        offGoalSince = nil; lastJudgmentAt = nil; alignment = .unclear
        heldStatus = nil; uncertaintyStartedAt = nil; uncertainDuration = 0
    }
    public mutating func accept(_ judgment: Judgment, at now: Date) {
        accept(alignment: judgment.alignment, at: now)
    }
    public mutating func acceptUncertainty(at now: Date) {
        accept(alignment: .unclear, at: now)
    }
    public mutating func acceptOffGoal(at now: Date) { accept(alignment: .offGoal, at: now) }
    /// Pauses elapsed distraction during checking without treating it as new evidence.
    public mutating func suspend(at now: Date) {
        guard offGoalSince != nil, uncertaintyStartedAt == nil else { return }
        uncertaintyStartedAt = now
    }
    private mutating func accept(alignment nextAlignment: Alignment, at now: Date) {
        // A stale gap must never count as confirmed distraction.
        if let last = lastJudgmentAt, now.timeIntervalSince(last) > maximumEvidenceAge { reset() }
        switch nextAlignment {
        case .unclear:
            if heldStatus == nil {
                let previousStatus = status(at: now)
                if [.focused, .drifting, .distracted].contains(previousStatus) {
                    heldStatus = previousStatus
                    if offGoalSince != nil && uncertaintyStartedAt == nil { uncertaintyStartedAt = now }
                }
            }
        case .offGoal:
            if let pausedAt = uncertaintyStartedAt { uncertainDuration += max(0, now.timeIntervalSince(pausedAt)) }
            heldStatus = nil; uncertaintyStartedAt = nil
            if offGoalSince == nil { offGoalSince = now; uncertainDuration = 0 }
        case .onGoal, .supporting:
            offGoalSince = nil; uncertainDuration = 0
            heldStatus = nil; uncertaintyStartedAt = nil
        }
        // Keep the raw choice even when its uncertainty leaves the prior visual cue in place.
        alignment = nextAlignment
        lastJudgmentAt = now
    }
    public func offGoalDuration(at now: Date) -> TimeInterval {
        guard let since = offGoalSince, let last = lastJudgmentAt,
              now.timeIntervalSince(last) <= maximumEvidenceAge else { return 0 }
        let end = min(now, uncertaintyStartedAt ?? now)
        return max(0, end.timeIntervalSince(since) - uncertainDuration)
    }
    public func status(at now: Date) -> FocusStatus {
        guard let last = lastJudgmentAt, now.timeIntervalSince(last) <= maximumEvidenceAge else { return .observing }
        if let heldStatus { return heldStatus }
        switch alignment {
        case .onGoal, .supporting: return .focused
        case .unclear: return .unclear
        case .offGoal:
            return offGoalDuration(at: now) >= redAfter ? .distracted : .drifting
        }
    }
}

public struct ActivityEntry: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var goal: String
    public var goalID: UUID?
    public var observation: Observation
    public var judgment: Judgment?
    public var correction: Alignment?
    public init(goal: String, observation: Observation, judgment: Judgment? = nil, correction: Alignment? = nil, goalID: UUID? = nil) {
        self.goal = goal; self.goalID = goalID; self.observation = observation; self.judgment = judgment; self.correction = correction
    }
}
