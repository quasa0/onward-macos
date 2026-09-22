import XCTest
@testable import OnwardCore

final class DistractionReminderTests: XCTestCase {
    func testStaleEvidenceStartsANewWarningEpisodeEvenAtTheSameElapsedTime() {
        var reminders = DistractionReminder()
        let first = Date(timeIntervalSince1970: 1000), second = Date(timeIntervalSince1970: 2000)
        XCTAssertTrue(reminders.shouldRemind(status: .distracted, confirmedSeconds: 45, episodeStartedAt: first))
        XCTAssertFalse(reminders.shouldRemind(status: .observing, confirmedSeconds: 0, episodeStartedAt: first))
        XCTAssertTrue(reminders.shouldRemind(status: .distracted, confirmedSeconds: 45, episodeStartedAt: second))
        XCTAssertFalse(reminders.shouldRemind(status: .distracted, confirmedSeconds: 46, episodeStartedAt: second))
    }
    func testRepeatUsesConfirmedTimeAndNeverCatchesUpInBursts() {
        var reminders = DistractionReminder()
        XCTAssertFalse(reminders.shouldRemind(status: .drifting, confirmedSeconds: 44))
        XCTAssertTrue(reminders.shouldRemind(status: .distracted, confirmedSeconds: 45))
        XCTAssertFalse(reminders.shouldRemind(status: .distracted, confirmedSeconds: 74.9))
        XCTAssertTrue(reminders.shouldRemind(status: .distracted, confirmedSeconds: 75))
        XCTAssertTrue(reminders.shouldRemind(status: .distracted, confirmedSeconds: 200))
        XCTAssertFalse(reminders.shouldRemind(status: .distracted, confirmedSeconds: 200))
    }

    func testHeldRedCheckingAndPauseNeverWarnAndRecoveryResetsEpisode() {
        var reminders = DistractionReminder()
        XCTAssertTrue(reminders.shouldRemind(status: .distracted, confirmedSeconds: 45))
        XCTAssertFalse(reminders.shouldRemind(status: .distracted, confirmedSeconds: 100, holdingStatus: true))
        XCTAssertFalse(reminders.shouldRemind(status: .observing, confirmedSeconds: 100))
        XCTAssertFalse(reminders.shouldRemind(status: .paused, confirmedSeconds: 100))
        XCTAssertFalse(reminders.shouldRemind(status: .distracted, confirmedSeconds: 60))
        XCTAssertFalse(reminders.shouldRemind(status: .focused, confirmedSeconds: 0))
        XCTAssertTrue(reminders.shouldRemind(status: .distracted, confirmedSeconds: 45))
    }
}
