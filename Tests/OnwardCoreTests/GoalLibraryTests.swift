import XCTest
@testable import OnwardCore

final class GoalLibraryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func goal(_ title: String, in library: inout GoalLibrary) throws -> SavedGoal {
        try library.saveGoal(title: title, goal: "Work on \(title)", context: "", at: now)
    }

    private func observation(project: String? = nil, thread: String = "Thread", url: String = "",
                             bundle: String = "app.editor", title: String = "Document") -> Observation {
        var value = Observation(); value.appName = "Editor"; value.bundleID = bundle
        value.capturedAt = now; value.windowTitle = title; value.url = url
        if let project {
            value.activeWorkspace = ActiveWorkspaceEvidence(project: project, thread: thread, source: "native", evidence: "breadcrumb")
        }
        return value
    }

    func testGoalCRUDPreservesIdentityAndKeepsAnnotationsIsolated() throws {
        var library = GoalLibrary()
        let first = try goal("First", in: &library)
        let second = try goal("Second", in: &library)
        XCTAssertEqual(library.activeGoalID, second.id)
        let note = try library.addAnnotation(goalID: first.id, alignment: .onGoal, note: "For first only",
                                             observation: observation(), at: now)
        let updated = try library.saveGoal(id: first.id, title: "Renamed", goal: first.goal,
                                           context: "New context", at: now.addingTimeInterval(10))
        XCTAssertEqual(updated.id, first.id); XCTAssertEqual(updated.createdAt, first.createdAt)
        XCTAssertEqual(updated.updatedAt, now.addingTimeInterval(10))
        XCTAssertEqual(library.annotations(for: first.id).map(\.id), [note.id])
        XCTAssertTrue(library.annotations(for: second.id).isEmpty)
        XCTAssertTrue(library.relevantNotes(for: second.id, observation: observation()).isEmpty)
        try library.selectGoal(second.id)
        try library.removeGoal(first.id)
        XCTAssertEqual(library.activeGoalID, second.id); XCTAssertTrue(library.annotations.isEmpty)
        try library.removeGoal(second.id)
        XCTAssertNil(library.activeGoalID); XCTAssertTrue(library.goals.isEmpty)
        XCTAssertThrowsError(try library.selectGoal(first.id))
        XCTAssertThrowsError(try library.saveGoal(id: first.id, title: "", goal: "Gone", context: ""))
    }

    func testAnnotationReviewCRUDAndUnclearExclusion() throws {
        var library = GoalLibrary(); let saved = try goal("First", in: &library)
        let activityID = UUID()
        let note = try library.addAnnotation(goalID: saved.id, alignment: .unclear, note: " Need review ",
                                             observation: observation(), activityID: activityID, at: now)
        XCTAssertEqual(note.activityID, activityID); XCTAssertEqual(note.note, "Need review")
        XCTAssertEqual(library.annotations(for: saved.id).count, 1)
        XCTAssertTrue(library.relevantNotes(for: saved.id, observation: observation()).isEmpty)
        try library.updateAnnotation(id: note.id, alignment: .supporting, note: "Reference for this document")
        XCTAssertEqual(library.annotations[0].createdAt, now)
        let examples = library.relevantNotes(for: saved.id, observation: observation())
        XCTAssertEqual(examples.count, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(examples[0].utf8)) as? [String: String])
        XCTAssertEqual(json["alignment"], "supporting")
        XCTAssertEqual(json["user_note"], "Reference for this document")
        XCTAssertTrue(try XCTUnwrap(json["scope"]).contains("not an unconditional"))
        try library.removeAnnotation(note.id)
        XCTAssertTrue(library.annotations.isEmpty)
        XCTAssertThrowsError(try library.updateAnnotation(id: note.id, alignment: .onGoal, note: ""))
        XCTAssertThrowsError(try library.addAnnotation(goalID: UUID(), alignment: .onGoal, note: "", observation: observation()))
    }

    func testWorkspaceConflictWinsOverAppURLAndDomainMatches() throws {
        var library = GoalLibrary(); let saved = try goal("First", in: &library)
        let url = "https://example.com/shared"
        try library.addAnnotation(goalID: saved.id, alignment: .onGoal, note: "Project A",
                                  observation: observation(project: "A", url: url), at: now)
        XCTAssertTrue(library.relevantNotes(for: saved.id, observation: observation(project: "B", url: url)).isEmpty)
        XCTAssertTrue(library.relevantNotes(for: saved.id, observation: observation(url: url)).isEmpty)
        XCTAssertEqual(library.relevantNotes(for: saved.id, observation: observation(project: "A", url: url)).count, 1)
        XCTAssertEqual(library.relevantNotes(for: saved.id, observation: observation(project: "A", thread: "Other")).count, 1)
    }

    func testURLRankingAndAppOnlyMatchesAreExcluded() throws {
        var library = GoalLibrary(); let saved = try goal("First", in: &library)
        try library.addAnnotation(goalID: saved.id, alignment: .onGoal, note: "domain",
                                  observation: observation(url: "https://example.com/other"), at: now.addingTimeInterval(10))
        try library.addAnnotation(goalID: saved.id, alignment: .offGoal, note: "exact",
                                  observation: observation(url: "https://example.com/current"), at: now)
        try library.addAnnotation(goalID: saved.id, alignment: .onGoal, note: "generic app",
                                  observation: observation(title: "Editor"), at: now)
        let matches = library.relevantNotes(for: saved.id, observation: observation(url: "https://example.com/current"))
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches[0].contains("exact")); XCTAssertTrue(matches[1].contains("domain"))
        XCTAssertTrue(library.relevantNotes(for: saved.id, observation: observation(title: "Editor")).isEmpty)
        XCTAssertTrue(library.relevantNotes(for: saved.id, observation: observation(url: "https://example.com.evil/other")).isEmpty)
        XCTAssertTrue(library.relevantNotes(for: saved.id, observation: observation(url: "https://example.com/other2", bundle: "app.other")).isEmpty)
    }

    func testWorkspaceThreadRanksBeforeSameProjectAndRecentDuplicates() throws {
        var library = GoalLibrary(); let saved = try goal("First", in: &library)
        try library.addAnnotation(goalID: saved.id, alignment: .onGoal, note: "same project",
                                  observation: observation(project: "A", thread: "Other"), at: now.addingTimeInterval(20))
        try library.addAnnotation(goalID: saved.id, alignment: .offGoal, note: "same thread",
                                  observation: observation(project: "A"), at: now)
        let matches = library.relevantNotes(for: saved.id, observation: observation(project: "A"))
        XCTAssertEqual(matches.count, 2); XCTAssertTrue(matches[0].contains("same thread"))
        XCTAssertEqual(library.relevantNotes(for: saved.id, observation: observation(project: "A"), limit: 1).count, 1)
        XCTAssertTrue(library.relevantNotes(for: saved.id, observation: observation(project: "A"), limit: 0).isEmpty)
    }

    func testCopiedEvidenceAndPromptBudgetsKeepAllSavedAnnotations() throws {
        var library = GoalLibrary(); let saved = try goal("First", in: &library)
        var source = observation(project: "A")
        let huge = String(repeating: "🙂", count: 8000)
        source.accessibilityText = huge; source.browserText = huge; source.ocrText = huge; source.selectedText = huge
        for _ in 0..<12 {
            try library.addAnnotation(goalID: saved.id, alignment: .onGoal, note: String(huge.prefix(3000)), observation: source, at: now)
        }
        let copy = try XCTUnwrap(library.annotations.first?.observation)
        XCTAssertEqual(copy.accessibilityText.utf8.count, 2000)
        XCTAssertEqual(copy.browserText.utf8.count, 2000); XCTAssertEqual(copy.ocrText.utf8.count, 2000)
        XCTAssertEqual(copy.selectedText.utf8.count, 1000); XCTAssertNil(copy.ocrLayout)
        XCTAssertEqual(source.ocrText, huge)
        let examples = library.relevantNotes(for: saved.id, observation: source, limit: 50)
        XCTAssertLessThanOrEqual(examples.count, 6)
        XCTAssertLessThanOrEqual(examples.reduce(0) { $0 + $1.utf8.count }, 12000)
        for example in examples { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(example.utf8))) }
        XCTAssertEqual(library.annotations.count, 12)
        var oversized = source; oversized.url = String(repeating: "x", count: 5000)
        XCTAssertTrue(GoalAnnotation.boundedObservation(oversized).url.isEmpty)
    }

    func testAtomicPersistenceAndInitialMigrationOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GoalLibraryFileStore(url: directory.appendingPathComponent("goals.json"))
        XCTAssertNil(try store.load())
        var library = try store.loadOrMigrate(goal: "Current goal", context: "Current context", at: now)
        let saved = try XCTUnwrap(library.activeGoal)
        XCTAssertEqual(saved.goal, "Current goal"); XCTAssertEqual(saved.context, "Current context")
        try library.addAnnotation(goalID: saved.id, alignment: .onGoal, note: "Keep this", observation: observation(), at: now)
        try store.save(library)
        XCTAssertEqual(try store.load(), library)
        XCTAssertEqual(try store.loadOrMigrate(goal: "Do not reimport", context: "Different", at: now), library)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        try library.removeGoal(saved.id); try store.save(library)
        XCTAssertTrue(try store.loadOrMigrate(goal: "Old preference", context: "", at: now).goals.isEmpty)
    }

    func testEmptyInitialMigrationIsPersistedAndCannotLaterImportPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GoalLibraryFileStore(url: directory.appendingPathComponent("goals.json"))
        XCTAssertTrue(try store.loadOrMigrate(goal: "  ", context: "", at: now).goals.isEmpty)
        XCTAssertNotNil(try store.load())
        XCTAssertTrue(try store.loadOrMigrate(goal: "Later old preference", context: "", at: now).goals.isEmpty)
    }

    func testCorruptionAndInvalidReferencesNeverOverwriteExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GoalLibraryFileStore(url: directory.appendingPathComponent("goals.json"))
        let valid = try store.loadOrMigrate(goal: "Keep", context: "", at: now)
        let original = try Data(contentsOf: store.url)
        let invalid = GoalLibrary(goals: valid.goals, activeGoalID: UUID())
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        let corrupt = Data("{ incomplete".utf8); try corrupt.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.loadOrMigrate(goal: "Replacement", context: "", at: now))
        XCTAssertThrowsError(try store.save(valid))
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
    }
}
