import XCTest
@testable import OnwardCore

final class BrowserTabIdentityTests: XCTestCase {
    func testStableTabAllowsTitleUpdatesButRejectsSameURLTabSwitch() {
        let first = BrowserTabIdentity(title: "Page", url: "https://example.com", tabID: "17")
        XCTAssertTrue(first.isSameTab(as: BrowserTabIdentity(title: "Page (2 unread)", url: first.url, tabID: "17")))
        XCTAssertFalse(first.isSameTab(as: BrowserTabIdentity(title: first.title, url: first.url, tabID: "18")))
        XCTAssertFalse(first.isSameTab(as: BrowserTabIdentity(title: first.title, url: "https://example.com/other", tabID: "17")))
        XCTAssertFalse(first.isSameTab(as: BrowserTabIdentity(title: first.title, url: first.url)))
    }

    func testBrowserWithoutStableTabIDRetainsConservativeTitleCheck() {
        let first = BrowserTabIdentity(title: "Page", url: "https://example.com")
        XCTAssertTrue(first.isSameTab(as: first))
        XCTAssertFalse(first.isSameTab(as: BrowserTabIdentity(title: "Different tab", url: first.url)))
        XCTAssertNil(BrowserTabIdentity(title: "", url: "", tabID: "").tabID)
    }

    func testTabIDRoundTripsAndMissingIDsRemainReadable() throws {
        var observation = Observation(); observation.browserTabID = "17"
        let data = try JSONEncoder().encode(observation)
        XCTAssertEqual(try JSONDecoder().decode(Observation.self, from: data).browserTabID, "17")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "browserTabID")
        let withoutID = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(Observation.self, from: withoutID).browserTabID)
    }
}
