import XCTest
@testable import OnwardCore

final class FocusSurfaceTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1000)

    private func observation() -> Observation {
        var value = Observation()
        value.bundleID = "net.imput.helium"; value.pid = 42; value.windowID = 7
        value.windowTitle = "Documentation"; value.tabTitle = "Vision"
        value.browserTabID = "tab-17"
        value.url = "https://example.com/docs"; value.capturedAt = epoch
        return value
    }

    func testContentRefreshKeepsAcceptedColorOnSameSurface() {
        let original = observation()
        let surface = FocusSurface(original)
        var refreshed = original
        refreshed.accessibilityText = "Scrolled to a new paragraph"
        refreshed.ocrText = "Newly rendered text"
        refreshed.selectedText = "A new selection"
        refreshed.focusedElement = "TextArea: Search"
        refreshed.windowTitle = "Documentation (updated)"
        refreshed.tabTitle = "Vision (2 new items)"
        refreshed.capturedAt = epoch.addingTimeInterval(5)
        XCTAssertNotEqual(original.fingerprint, refreshed.fingerprint)
        XCTAssertTrue(surface.canDisplayJudgment(for: refreshed, foregroundPID: 42, at: refreshed.capturedAt))
    }

    func testAppWindowAndTabChangesInvalidateAcceptedColor() {
        let original = observation()
        let surface = FocusSurface(original)
        let changes: [(inout Observation) -> Void] = [
            { $0.pid = 43 }, { $0.bundleID = "com.apple.Notes" }, { $0.windowID = 8 },
            { $0.browserTabID = "tab-18" },
            { $0.url = "https://example.com/unrelated" }
        ]
        for change in changes {
            var changed = original; change(&changed)
            XCTAssertFalse(surface.canDisplayJudgment(for: changed, foregroundPID: changed.pid, at: epoch))
        }
        XCTAssertFalse(surface.canDisplayJudgment(for: original, foregroundPID: 99, at: epoch))
        XCTAssertFalse(surface.canDisplayJudgment(for: original, foregroundPID: nil, at: epoch))
        var nativeDocument = original; nativeDocument.url = ""; nativeDocument.tabTitle = ""; nativeDocument.browserTabID = nil
        let nativeSurface = FocusSurface(nativeDocument)
        nativeDocument.windowTitle = "Another document"
        XCTAssertFalse(nativeSurface.canDisplayJudgment(for: nativeDocument, foregroundPID: 42, at: epoch))
    }

    func testStaleCaptureCannotKeepTheColorAlive() {
        let current = observation()
        let surface = FocusSurface(current)
        XCTAssertTrue(surface.canDisplayJudgment(for: current, foregroundPID: 42, at: epoch.addingTimeInterval(11.9)))
        XCTAssertFalse(surface.canDisplayJudgment(for: current, foregroundPID: 42, at: epoch.addingTimeInterval(12)))
        XCTAssertFalse(surface.canDisplayJudgment(for: current, foregroundPID: 42, at: epoch.addingTimeInterval(-1)))
    }

    func testSelectedWorkspaceAndThreadChangesInvalidateCurrentJudgment() {
        var original = observation()
        original.activeWorkspace = ActiveWorkspaceEvidence(project: "Atlas", thread: "Sign-in", source: "Accessibility", evidence: "Header")
        let surface = FocusSurface(original)
        var changed = original
        changed.activeWorkspace = ActiveWorkspaceEvidence(project: "Beacon", thread: "Sign-in", source: "Accessibility", evidence: "Header")
        XCTAssertFalse(surface.canDisplayJudgment(for: changed, foregroundPID: 42, at: epoch))
        changed.activeWorkspace = ActiveWorkspaceEvidence(project: "Atlas", thread: "Design", source: "Accessibility", evidence: "Header")
        XCTAssertFalse(surface.canDisplayJudgment(for: changed, foregroundPID: 42, at: epoch))
        changed.activeWorkspace = ActiveWorkspaceEvidence(project: "Atlas", thread: "Sign-in", source: "Local OCR", evidence: "Same header")
        XCTAssertTrue(surface.canDisplayJudgment(for: changed, foregroundPID: 42, at: epoch))
    }

    func testFreshCaptureDoesNotExtendJudgmentLifetime() {
        var current = observation()
        let surface = FocusSurface(current)
        var policy = FocusPolicy()
        policy.accept(Judgment(alignment: .onGoal, probabilities: ["on_goal": 1], confidence: 1), at: epoch)
        current.capturedAt = epoch.addingTimeInterval(31)
        XCTAssertTrue(surface.canDisplayJudgment(for: current, foregroundPID: 42, at: current.capturedAt))
        XCTAssertEqual(policy.status(at: current.capturedAt), .observing)
    }
}
