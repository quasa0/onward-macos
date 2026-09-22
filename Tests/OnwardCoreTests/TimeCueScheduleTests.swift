import XCTest
@testable import OnwardCore

final class TimeCueScheduleTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testEveryPresetAlignsToClockBoundariesRatherThanEnableTime() {
        XCTAssertEqual(TimeCueInterval.allCases.map(\.rawValue), [5, 10, 15, 30, 60])
        for interval in TimeCueInterval.allCases {
            let width = interval.seconds
            let next = TimeCueSchedule.nextBoundary(after: date(60000 + width + 0.125), interval: interval)
            XCTAssertEqual(next, date(60000 + 2 * width))
            XCTAssertEqual(next.timeIntervalSince1970.truncatingRemainder(dividingBy: width), 0)
            XCTAssertEqual(TimeCueSchedule.nextBoundary(after: next, interval: interval), next.addingTimeInterval(width))
        }
    }

    func testQuarterMinuteBoundariesUseActualClockSecondsAndMinuteRollover() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 22,
            hour: 15, minute: 35, second: 14))).addingTimeInterval(0.875)
        var boundary = start
        for expectedSecond in [15, 30, 45, 0] {
            boundary = TimeCueSchedule.nextBoundary(after: boundary, interval: .fifteenSeconds)
            let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: boundary)
            XCTAssertEqual(parts.hour, 15)
            XCTAssertEqual(parts.minute, expectedSecond == 0 ? 36 : 35)
            XCTAssertEqual(parts.second, expectedSecond)
            XCTAssertEqual(parts.nanosecond, 0)
        }
    }

    func testFractionalAndPreEpochDatesStillProduceStrictlyFutureBoundaries() {
        XCTAssertEqual(TimeCueSchedule.nextBoundary(after: date(59.999), interval: .fifteenSeconds), date(60))
        XCTAssertEqual(TimeCueSchedule.nextBoundary(after: date(60), interval: .fifteenSeconds), date(75))
        XCTAssertEqual(TimeCueSchedule.nextBoundary(after: date(-0.125), interval: .fifteenSeconds), date(0))
        XCTAssertEqual(TimeCueSchedule.nextBoundary(after: date(-15), interval: .fifteenSeconds), date(0))
        XCTAssertEqual(TimeCueSchedule.nextBoundary(after: date(-15.125), interval: .fifteenSeconds), date(-15))
    }

    func testEarlyAndDuplicateCallbacksCannotFire() {
        var schedule = TimeCueSchedule(interval: .fifteenSeconds, now: date(1))
        XCTAssertEqual(schedule.nextFireDate, date(15))
        XCTAssertFalse(schedule.consume(at: date(14.999)))
        XCTAssertEqual(schedule.nextFireDate, date(15))
        XCTAssertTrue(schedule.consume(at: date(15)))
        XCTAssertEqual(schedule.nextFireDate, date(30))
        XCTAssertFalse(schedule.consume(at: date(15)))
        XCTAssertFalse(schedule.consume(at: date(15.4)))
        XCTAssertTrue(schedule.consume(at: date(30.1)))
    }

    func testOnlySmallSchedulingLatenessIsAccepted() {
        for (lateness, expected) in [(0.0, true), (0.25, true), (0.5, true), (0.501, false), (4.0, false)] {
            var schedule = TimeCueSchedule(interval: .fiveSeconds, now: date(59))
            XCTAssertEqual(schedule.consume(at: date(60 + lateness)), expected, "lateness: \(lateness)")
            XCTAssertEqual(schedule.nextFireDate, date(65))
        }
    }

    func testWakeOrForwardClockJumpSkipsMissedCuesWithoutCatchupBurst() {
        var schedule = TimeCueSchedule(interval: .fifteenSeconds, now: date(1))
        XCTAssertFalse(schedule.consume(at: date(120)))
        XCTAssertEqual(schedule.nextFireDate, date(135))
        for _ in 0..<10 { XCTAssertFalse(schedule.consume(at: date(120.1))) }
        XCTAssertTrue(schedule.consume(at: date(135)))
        XCTAssertFalse(schedule.consume(at: date(135)))
        XCTAssertEqual(schedule.nextFireDate, date(150))
    }

    func testBackwardClockJumpReanchorsWithoutAnImmediateCue() {
        var schedule = TimeCueSchedule(interval: .fifteenSeconds, now: date(120))
        XCTAssertTrue(schedule.consume(at: date(135)))
        XCTAssertFalse(schedule.consume(at: date(90)))
        XCTAssertEqual(schedule.nextFireDate, date(105))
        XCTAssertFalse(schedule.consume(at: date(90)))
        XCTAssertFalse(schedule.consume(at: date(104.9)))
        XCTAssertTrue(schedule.consume(at: date(105)))
        XCTAssertFalse(schedule.consume(at: date(105)))
        XCTAssertEqual(schedule.nextFireDate, date(120))
    }

    func testNewScheduleStartsStrictlyAfterEnableOrResumeWithoutImmediateCue() {
        var schedule = TimeCueSchedule(interval: .oneMinute, now: date(180))
        XCTAssertEqual(schedule.nextFireDate, date(240))
        XCTAssertFalse(schedule.consume(at: date(180)))
        XCTAssertTrue(schedule.consume(at: date(240)))
        schedule = TimeCueSchedule(interval: .tenSeconds, now: date(240))
        XCTAssertEqual(schedule.nextFireDate, date(250))
        XCTAssertFalse(schedule.consume(at: date(240)))
        XCTAssertTrue(schedule.consume(at: date(250)))
    }
}
