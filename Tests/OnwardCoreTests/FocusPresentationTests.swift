import XCTest
@testable import OnwardCore

final class FocusPresentationTests: XCTestCase {
    private let operationalStates: [FocusStatus] = [.ready, .observing, .unclear, .idle, .paused, .unavailable]

    func testEveryEstablishedColorSurvivesEveryOperationalState() {
        for (established, seconds) in [(FocusStatus.focused, 0), (.drifting, 17), (.distracted, 80)] {
            var presentation = FocusPresentation()
            presentation.update(status: established, offGoalSeconds: seconds)
            for operational in operationalStates {
                presentation.update(status: operational, offGoalSeconds: 999)
                XCTAssertEqual(presentation.establishedStatus, established)
                XCTAssertEqual(presentation.status(for: operational), established)
                XCTAssertEqual(presentation.offGoalSeconds, seconds)
            }
        }
    }

    func testRepeatedCheckingCannotAdvanceYellowOrItsTimer() {
        var presentation = FocusPresentation()
        presentation.update(status: .drifting, offGoalSeconds: 44)
        for seconds in 45...180 {
            presentation.update(status: .observing, offGoalSeconds: seconds)
            XCTAssertEqual(presentation.status(for: .observing), .drifting)
            XCTAssertEqual(presentation.offGoalSeconds, 44)
        }
    }

    func testNewDecisiveStatusReplacesTheEstablishedCue() {
        var presentation = FocusPresentation()
        presentation.update(status: .focused, offGoalSeconds: 0)
        presentation.update(status: .drifting, offGoalSeconds: 12)
        XCTAssertEqual(presentation.status(for: .observing), .drifting)
        XCTAssertEqual(presentation.offGoalSeconds, 12)
        presentation.update(status: .distracted, offGoalSeconds: 46)
        XCTAssertEqual(presentation.status(for: .unclear), .distracted)
        XCTAssertEqual(presentation.offGoalSeconds, 46)
        presentation.update(status: .focused, offGoalSeconds: 46)
        XCTAssertEqual(presentation.status(for: .observing), .focused)
        XCTAssertEqual(presentation.offGoalSeconds, 0)
    }

    func testInitialAndResetPresentationUseTheOperationalState() {
        var presentation = FocusPresentation()
        for operational in operationalStates {
            presentation.update(status: operational, offGoalSeconds: 999)
            XCTAssertNil(presentation.establishedStatus)
            XCTAssertEqual(presentation.status(for: operational), operational)
            XCTAssertEqual(presentation.offGoalSeconds, 0)
        }
        presentation.update(status: .distracted, offGoalSeconds: 70)
        presentation.reset()
        XCTAssertNil(presentation.establishedStatus)
        XCTAssertEqual(presentation.offGoalSeconds, 0)
        for operational in operationalStates { XCTAssertEqual(presentation.status(for: operational), operational) }
    }

    func testDisplayedDurationCannotBeNegative() {
        var presentation = FocusPresentation()
        presentation.update(status: .drifting, offGoalSeconds: -1)
        XCTAssertEqual(presentation.offGoalSeconds, 0)
        presentation.update(status: .distracted, offGoalSeconds: -100)
        XCTAssertEqual(presentation.offGoalSeconds, 0)
    }
}
