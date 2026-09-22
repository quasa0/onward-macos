import XCTest
@testable import OnwardCore

final class NativeWorkspaceTests: XCTestCase {
    func testOnlyVerifiedAppLandmarkStartsWorkspaceScope() {
        XCTAssertTrue(NativeWorkspaceBreadcrumb.isRoot(bundleID: "com.t3tools.t3code", role: "AXGroup", labels: ["Thread breadcrumb"]))
        XCTAssertFalse(NativeWorkspaceBreadcrumb.isRoot(bundleID: "example.app", role: "AXGroup", labels: ["Thread breadcrumb"]))
        XCTAssertFalse(NativeWorkspaceBreadcrumb.isRoot(bundleID: "com.t3tools.t3code", role: "AXStaticText", labels: ["Thread breadcrumb"]))
        XCTAssertFalse(NativeWorkspaceBreadcrumb.isRoot(bundleID: "com.t3tools.t3code", role: "AXGroup", labels: ["Sidebar"]))
    }

    func testNativeButtonLabelsIdentifyWorkspaceWithoutTruncatedVisibleTitle() {
        var breadcrumb = NativeWorkspaceBreadcrumb()
        breadcrumb.record(role: "AXButton", labels: ["New thread in Atlas", "Atlas"])
        breadcrumb.record(role: "AXPopUpButton", labels: ["Thread actions for Create videos entirely in messages", "Create videos…"])
        breadcrumb.record(role: "AXButton", labels: ["New thread in Atlas"])
        XCTAssertEqual(breadcrumb.evidence?.project, "Atlas")
        XCTAssertEqual(breadcrumb.evidence?.thread, "Create videos entirely in messages")
        XCTAssertEqual(breadcrumb.evidence?.source, "macOS Accessibility")
    }

    func testConversationTextAndIncompleteOrAmbiguousLabelsDoNotInventWorkspace() {
        var breadcrumb = NativeWorkspaceBreadcrumb()
        breadcrumb.record(role: "AXStaticText", labels: ["New thread in Other", "Thread actions for Other task"])
        XCTAssertNil(breadcrumb.evidence)
        breadcrumb.record(role: "AXButton", labels: ["New thread in Atlas"])
        XCTAssertNil(breadcrumb.evidence)
        breadcrumb.record(role: "AXPopUpButton", labels: ["Thread actions for Search"])
        XCTAssertNotNil(breadcrumb.evidence)
        breadcrumb.record(role: "AXPopUpButton", labels: ["Thread actions for Different task"])
        XCTAssertNil(breadcrumb.evidence)
    }

    func testSeparateBreadcrumbsCannotCombineProjectAndThread() {
        var first = NativeWorkspaceBreadcrumb(), second = NativeWorkspaceBreadcrumb()
        first.record(role: "AXButton", labels: ["New thread in Atlas"])
        second.record(role: "AXPopUpButton", labels: ["Thread actions for Search"])
        XCTAssertNil(first.evidence); XCTAssertNil(second.evidence)
        first.record(role: "AXPopUpButton", labels: ["Thread actions for Search"])
        XCTAssertNotNil(first.evidence)
        second.record(role: "AXButton", labels: ["New thread in Other"])
        XCTAssertEqual(second.evidence?.project, "Other")
    }

    func testBlankAndOversizedNamesAreRejectedWithoutPartialIdentity() {
        var breadcrumb = NativeWorkspaceBreadcrumb()
        breadcrumb.record(role: "AXButton", labels: ["New thread in    "])
        breadcrumb.record(role: "AXPopUpButton", labels: ["Thread actions for Search"])
        XCTAssertNil(breadcrumb.evidence)
        breadcrumb.record(role: "AXButton", labels: ["New thread in " + String(repeating: "a", count: 301)])
        XCTAssertNil(breadcrumb.evidence)
    }

    private let window = CGRect(x: -1200, y: 40, width: 1200, height: 850)
    private let breadcrumb = CGRect(x: -850, y: 60, width: 600, height: 30)

    func testSidebarAndHeaderTextCannotSuppressOCR() {
        let text = String(repeating: "Readable text ", count: 40)
        let sidebar = NativeTextRegion(text: text, frame: CGRect(x: -1180, y: 120, width: 280, height: 100))
        let header = NativeTextRegion(text: text, frame: CGRect(x: -820, y: 65, width: 500, height: 20))
        XCTAssertFalse(NativeWorkspaceCoverage.hasSufficientText(breadcrumb: breadcrumb, window: window,
            regions: [sidebar, header], traversalComplete: true))
        let body = NativeTextRegion(text: text, frame: CGRect(x: -820, y: 120, width: 500, height: 100))
        XCTAssertTrue(NativeWorkspaceCoverage.hasSufficientText(breadcrumb: breadcrumb, window: window,
            regions: [sidebar, header, body], traversalComplete: true))
    }

    func testMissingGeometryIncompleteTraversalAndOffscreenTextKeepOCR() {
        let body = NativeTextRegion(text: String(repeating: "content ", count: 50),
            frame: CGRect(x: -820, y: 120, width: 500, height: 100))
        XCTAssertFalse(NativeWorkspaceCoverage.hasSufficientText(breadcrumb: nil, window: window,
            regions: [body], traversalComplete: true))
        XCTAssertFalse(NativeWorkspaceCoverage.hasSufficientText(breadcrumb: breadcrumb, window: nil,
            regions: [body], traversalComplete: true))
        XCTAssertFalse(NativeWorkspaceCoverage.hasSufficientText(breadcrumb: breadcrumb, window: window,
            regions: [body], traversalComplete: false))
        var outside = body; outside.frame.origin.y = 1000
        XCTAssertFalse(NativeWorkspaceCoverage.hasSufficientText(breadcrumb: breadcrumb, window: window,
            regions: [outside], traversalComplete: true))
    }

    func testRepeatedNativeTextDoesNotInflateBodyCoverage() {
        let repeated = NativeTextRegion(text: String(repeating: "x", count: 200),
            frame: CGRect(x: -820, y: 120, width: 500, height: 100))
        XCTAssertFalse(NativeWorkspaceCoverage.hasSufficientText(breadcrumb: breadcrumb, window: window,
            regions: [repeated, repeated], traversalComplete: true))
    }
}
