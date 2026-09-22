import XCTest
@testable import OnwardCore

final class DistractionReminderTests: XCTestCase {
    func testFirstRedWarnsImmediatelyAndRepeatsAtChosenDeadline() {
        var reminders = DistractionReminder(intervalRange: 7...7)
        XCTAssertNil(reminders.cue(isRedVisible: false, at: 100))
        XCTAssertEqual(reminders.cue(isRedVisible: true, at: 101), .enteredRed)
        XCTAssertNil(reminders.cue(isRedVisible: true, at: 107.99))
        XCTAssertEqual(reminders.cue(isRedVisible: true, at: 108), .repeated)
        XCTAssertEqual(reminders.nextReminderAt, 115)
    }
    func testRandomIntervalsStayWithinThreeToSevenSeconds() {
        var reminders = DistractionReminder()
        var now: TimeInterval = 100
        for index in 0..<100 {
            XCTAssertEqual(reminders.cue(isRedVisible: true, at: now), index == 0 ? .enteredRed : .repeated)
            guard let deadline = reminders.nextReminderAt else { return XCTFail("No next warning") }
            XCTAssertTrue((3...7).contains(deadline - now))
            XCTAssertNil(reminders.cue(isRedVisible: true, at: deadline - 0.01))
            now = deadline
        }
    }
    func testRetainedRedKeepsCadenceButHidingRedResetsIt() {
        var reminders = DistractionReminder(intervalRange: 3...3)
        XCTAssertEqual(reminders.cue(isRedVisible: true, at: 100), .enteredRed)
        // Checking retains the same visible red, so its sound cadence continues.
        XCTAssertEqual(reminders.cue(isRedVisible: true, at: 103), .repeated)
        XCTAssertNil(reminders.cue(isRedVisible: false, at: 104))
        XCTAssertNil(reminders.nextReminderAt)
        XCTAssertEqual(reminders.cue(isRedVisible: true, at: 105), .enteredRed)
    }
    func testDelayedCallbackNeverReplaysMissedWarningsInABurst() {
        var reminders = DistractionReminder(intervalRange: 3...3)
        XCTAssertEqual(reminders.cue(isRedVisible: true, at: 100), .enteredRed)
        XCTAssertEqual(reminders.cue(isRedVisible: true, at: 200), .repeated)
        XCTAssertNil(reminders.cue(isRedVisible: true, at: 200))
        XCTAssertEqual(reminders.nextReminderAt, 203)
        XCTAssertNil(reminders.cue(isRedVisible: true, at: .nan))
        XCTAssertNil(reminders.nextReminderAt)
    }
}
