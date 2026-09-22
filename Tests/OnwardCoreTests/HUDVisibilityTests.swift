import CoreGraphics
import XCTest
@testable import OnwardCore

final class HUDVisibilityTests: XCTestCase {
    let frame = CGRect(x: 100, y: 700, width: 368, height: 48)

    func testApproachHidesBeforePointerReachesPillAndStaysHiddenAtTheEdge() {
        var policy = HUDVisibilityPolicy()
        XCTAssertTrue(policy.shouldShow(enabled: true, pointer: CGPoint(x: 300, y: 500), frame: frame, at: 0))
        XCTAssertFalse(policy.shouldShow(enabled: true, pointer: CGPoint(x: 300, y: 680), frame: frame, at: 1))
        XCTAssertFalse(policy.shouldShow(enabled: true, pointer: CGPoint(x: 300, y: 724), frame: frame, at: 2))
        // Just outside the entrance region still hides it while the tab is in use.
        XCTAssertFalse(policy.shouldShow(enabled: true, pointer: CGPoint(x: 300, y: 670), frame: frame, at: 4))
    }

    func testReturnWaitsForSustainedClearanceAndHandlesAnotherDisplay() {
        var policy = HUDVisibilityPolicy()
        let otherDisplay = frame.offsetBy(dx: -1920, dy: -900)
        let over = CGPoint(x: otherDisplay.midX, y: otherDisplay.midY)
        let far = CGPoint(x: otherDisplay.midX, y: otherDisplay.minY - 100)
        XCTAssertFalse(policy.shouldShow(enabled: true, pointer: over, frame: otherDisplay, at: 0))
        XCTAssertFalse(policy.shouldShow(enabled: true, pointer: far, frame: otherDisplay, at: 1))
        XCTAssertFalse(policy.shouldShow(enabled: true, pointer: over, frame: otherDisplay, at: 1.2))
        XCTAssertFalse(policy.shouldShow(enabled: true, pointer: far, frame: otherDisplay, at: 1.3))
        XCTAssertTrue(policy.shouldShow(enabled: true, pointer: far, frame: otherDisplay, at: 1.7))
        XCTAssertFalse(policy.shouldShow(enabled: false, pointer: far, frame: otherDisplay, at: 2))
    }
}
