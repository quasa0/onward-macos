import CoreGraphics
import XCTest
@testable import OnwardCore

final class SystemActivityTests: XCTestCase {
    func testIdleTimeReadsAnyInputInsteadOfNullEvents() {
        var calls = 0
        let idle = SystemActivity.idleSeconds { state, event in
            calls += 1
            XCTAssertEqual(state, .combinedSessionState)
            // Apple's any-input selector is all 32 bits set. The null event is zero.
            XCTAssertEqual(event.rawValue, 0xffff_ffff)
            XCTAssertNotEqual(event, .null)
            return event.rawValue == 0xffff_ffff ? 0.25 : 900
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(idle, 0.25, "Recent keyboard/mouse input must not be reported as Away.")
    }
}
