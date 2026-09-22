import XCTest
@testable import OnwardCore

final class GoalIdentityTests: XCTestCase {
    func testActivityRetainsStableGoalIdentityWhenInstructionsMatch() throws {
        let first = ActivityEntry(goal: "Fix sign-in", observation: Observation(), goalID: UUID())
        let second = ActivityEntry(goal: "Fix sign-in", observation: Observation(), goalID: UUID())
        let restored = try JSONDecoder().decode(ActivityEntry.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(restored.goalID, first.goalID)
        XCTAssertNotEqual(restored.goalID, second.goalID)
    }

    func testPreLibraryHistoryDecodesWithoutInventingGoalIdentity() throws {
        let entry = ActivityEntry(goal: "Original goal", observation: Observation())
        let data = try JSONEncoder().encode(entry)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["goalID"])
        XCTAssertNil(try JSONDecoder().decode(ActivityEntry.self, from: data).goalID)
    }
}
