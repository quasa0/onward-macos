import XCTest
@testable import OnwardCore

final class OCRLayoutTests: XCTestCase {
    private func line(_ text: String, x: Double, y: Double, width: Double = 0.15, height: Double = 0.012) -> OCRTextLine {
        OCRTextLine(text: text, x: x, y: y, width: width, height: height)
    }
    private var fixture: [OCRTextLine] {
        [line("T3 Code", x: 0.10, y: 0.04, width: 0.05),
         line("J Atlas / Implement document search", x: 0.34, y: 0.04, width: 0.30),
         line("Goal: a different project", x: 0.68, y: 0.04, width: 0.23),
         line("Atlas", x: 0.03, y: 0.30),
         line("Other project", x: 0.03, y: 0.15),
         line("Unrelated sidebar thread", x: 0.03, y: 0.18, width: 0.25),
         line("Implement document search", x: 0.03, y: 0.33, width: 0.26),
         line("The main conversation mentions a different project.", x: 0.35, y: 0.18, width: 0.60)]
    }
    func testBreadcrumbSeparatesActiveProjectFromSidebarAndGoalOverlay() {
        let result = OCRLayout.analyze(fixture, bundleID: "com.t3tools.t3code")
        XCTAssertEqual(result.activeWorkspace?.project, "Atlas")
        XCTAssertEqual(result.activeWorkspace?.thread, "Implement document search")
        XCTAssertTrue(result.layout?.mainContentText.contains("main conversation") ?? false)
        XCTAssertFalse(result.layout?.mainContentText.contains("Unrelated sidebar") ?? true)
        XCTAssertTrue(result.layout?.sidebarText.contains("Unrelated sidebar") ?? false)
        XCTAssertFalse(result.layout?.headerText.contains("Goal:") ?? true)
        XCTAssertEqual(result.layout?.headerLines.count, 1)
    }
    func testReorderedLinesAndSeparateBreadcrumbPreserveIdentity() {
        var lines = fixture.filter { !$0.text.contains("J Atlas /") }
        lines.append(line("Atlas", x: 0.35, y: 0.04, width: 0.06))
        lines.append(line("Implement document search", x: 0.44, y: 0.04, width: 0.20))
        let result = OCRLayout.analyze(Array(lines.reversed()), bundleID: "com.t3tools.t3code")
        XCTAssertEqual(result.activeWorkspace?.project, "Atlas")
        XCTAssertEqual(result.activeWorkspace?.thread, "Implement document search")
        XCTAssertEqual(result.layout?.headerLines.count, 2)
    }
    func testSidebarAloneAndMissingHeaderDoNotInventAnActiveProject() {
        let noBreadcrumb = fixture.filter { !$0.text.contains("J Atlas /") }
        XCTAssertNil(OCRLayout.analyze(noBreadcrumb, bundleID: "com.t3tools.t3code").activeWorkspace)
        let noAnchor = fixture.filter { $0.text != "T3 Code" }
        XCTAssertNil(OCRLayout.analyze(noAnchor, bundleID: "com.t3tools.t3code").activeWorkspace)
        let noCorroboration = fixture.filter { $0.text != "Atlas" }
        XCTAssertNil(OCRLayout.analyze(noCorroboration, bundleID: "com.t3tools.t3code").activeWorkspace)
    }
    func testUnsupportedApplicationRetainsPlainOCRWithoutWorkspaceInference() {
        let result = OCRLayout.analyze(fixture, bundleID: "example.other")
        XCTAssertNil(result.activeWorkspace); XCTAssertNil(result.layout)
        XCTAssertTrue(result.text.contains("Implement document search"))
    }
    func testOptionalWorkspaceFieldsDecodeOlderObservationsAndRoundTripNewEvidence() throws {
        var observation = Observation()
        let oldData = try JSONEncoder().encode(observation)
        XCTAssertNil(try JSONDecoder().decode(Observation.self, from: oldData).activeWorkspace)
        let result = OCRLayout.analyze(fixture, bundleID: "com.t3tools.t3code")
        observation.activeWorkspace = result.activeWorkspace; observation.ocrLayout = result.layout
        XCTAssertEqual(try JSONDecoder().decode(Observation.self, from: JSONEncoder().encode(observation)), observation)
    }
}
