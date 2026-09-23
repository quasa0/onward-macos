import Foundation

public struct SavedGoal: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var goal: String
    public var context: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, goal: String, context: String,
                createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.title = title; self.goal = goal; self.context = context
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
}

public struct GoalAnnotation: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var goalID: UUID
    public var createdAt: Date
    public var alignment: Alignment
    public var note: String
    public var observation: Observation
    public var activityID: UUID?
    public var originalJudgment: Judgment?

    public init(id: UUID = UUID(), goalID: UUID, createdAt: Date = Date(), alignment: Alignment,
                note: String, observation: Observation, activityID: UUID? = nil, originalJudgment: Judgment? = nil) {
        self.id = id; self.goalID = goalID; self.createdAt = createdAt
        self.alignment = alignment; self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.observation = Self.boundedObservation(observation); self.activityID = activityID
        self.originalJudgment = originalJudgment
    }

    /// A durable copy, independent of the rotating activity history and OCR layout.
    public static func boundedObservation(_ input: Observation) -> Observation {
        var copy = input
        copy.appName = boundedText(copy.appName, bytes: 300)
        copy.bundleID = boundedText(copy.bundleID, bytes: 300)
        copy.windowTitle = boundedText(copy.windowTitle, bytes: 1000)
        copy.tabTitle = boundedText(copy.tabTitle, bytes: 1000)
        copy.browserTabID = copy.browserTabID.map { boundedText($0, bytes: 300) }
        // Do not turn an oversized URL into a misleading exact-prefix identity.
        if copy.url.utf8.count > 4096 { copy.url = "" }
        copy.focusedElement = boundedText(copy.focusedElement, bytes: 500)
        copy.selectedText = boundedText(copy.selectedText, bytes: 1000)
        copy.accessibilityText = boundedText(copy.accessibilityText, bytes: 2000)
        copy.browserText = boundedText(copy.browserText, bytes: 2000)
        copy.ocrText = boundedText(copy.ocrText, bytes: 2000)
        copy.ocrLayout = nil
        if var workspace = copy.activeWorkspace {
            if workspace.project.utf8.count > 300 || workspace.thread.utf8.count > 600 {
                copy.activeWorkspace = nil
            } else {
                workspace.source = boundedText(workspace.source, bytes: 150)
                workspace.evidence = boundedText(workspace.evidence, bytes: 1000)
                copy.activeWorkspace = workspace
            }
        }
        copy.sources = copy.sources.prefix(8).map { boundedText($0, bytes: 100) }
        copy.warnings = copy.warnings.prefix(5).map { boundedText($0, bytes: 250) }
        return copy
    }
}

extension Alignment {
    /// Relevant/irrelevant category for review. `nil` means Jev was unsure.
    public var isRelevant: Bool? {
        switch self {
        case .onGoal, .supporting: return true
        case .offGoal: return false
        case .unclear: return nil
        }
    }
}

/// How the user's saved answer relates to Jev's original answer for the same activity.
public enum ReviewProvenance: Equatable, Sendable {
    case confirmed, corrected, decidedWhileUnsure, unknown
    public init(original: Judgment?, answer: Alignment) {
        guard let original else { self = .unknown; return }
        guard let jev = original.alignment.isRelevant, let user = answer.isRelevant else {
            self = original.alignment == .unclear ? .decidedWhileUnsure : .unknown; return
        }
        self = jev == user ? .confirmed : .corrected
    }
}

/// Jev's recorded answer for one retained activity entry.
public struct RetainedJudgment: Equatable, Sendable {
    public var observationID: UUID
    public var judgment: Judgment
    public init(observationID: UUID, judgment: Judgment) { self.observationID = observationID; self.judgment = judgment }
}

public enum GoalLibraryError: LocalizedError, Equatable {
    case emptyGoal, textTooLong, goalNotFound, annotationNotFound, invalidLibrary, corruptFile
    public var errorDescription: String? {
        switch self {
        case .emptyGoal: "Enter a goal before saving it."
        case .textTooLong: "The title is limited to 300 bytes; goals, context, and notes to 16,000 bytes each."
        case .goalNotFound: "The saved goal no longer exists."
        case .annotationNotFound: "The annotation no longer exists."
        case .invalidLibrary: "The goal library contains invalid or inconsistent records."
        case .corruptFile: "The saved goal library could not be read. It has been preserved without changes."
        }
    }
}

public struct GoalLibrary: Codable, Equatable, Sendable {
    public private(set) var goals: [SavedGoal]
    public private(set) var annotations: [GoalAnnotation]
    public private(set) var activeGoalID: UUID?

    public init(goals: [SavedGoal] = [], annotations: [GoalAnnotation] = [], activeGoalID: UUID? = nil) {
        self.goals = goals; self.annotations = annotations; self.activeGoalID = activeGoalID
    }

    public var activeGoal: SavedGoal? { goals.first { $0.id == activeGoalID } }

    /// Creates or updates a goal, and selects the saved record.
    @discardableResult public mutating func saveGoal(id: UUID? = nil, title: String, goal: String,
                                                    context: String, at now: Date = Date()) throws -> SavedGoal {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { throw GoalLibraryError.emptyGoal }
        try Self.checkText(title: title, goal: goal, context: context)
        let titleValue = title.isEmpty ? boundedText(goal.components(separatedBy: .newlines).first ?? goal, bytes: 100) : title
        let saved: SavedGoal
        if let id {
            guard let index = goals.firstIndex(where: { $0.id == id }) else { throw GoalLibraryError.goalNotFound }
            saved = SavedGoal(id: id, title: titleValue, goal: goal, context: context,
                              createdAt: goals[index].createdAt, updatedAt: now)
            goals[index] = saved
        } else {
            saved = SavedGoal(title: titleValue, goal: goal, context: context, createdAt: now)
            goals.append(saved)
        }
        activeGoalID = saved.id
        return saved
    }

    public mutating func selectGoal(_ id: UUID?) throws {
        guard id == nil || goals.contains(where: { $0.id == id }) else { throw GoalLibraryError.goalNotFound }
        activeGoalID = id
    }

    public mutating func removeGoal(_ id: UUID) throws {
        guard goals.contains(where: { $0.id == id }) else { throw GoalLibraryError.goalNotFound }
        goals.removeAll { $0.id == id }
        annotations.removeAll { $0.goalID == id }
        if activeGoalID == id { activeGoalID = nil }
    }

    @discardableResult public mutating func addAnnotation(goalID: UUID, alignment: Alignment, note: String,
                                                         observation: Observation, activityID: UUID? = nil, originalJudgment: Judgment? = nil,
                                                         at now: Date = Date()) throws -> GoalAnnotation {
        guard goals.contains(where: { $0.id == goalID }) else { throw GoalLibraryError.goalNotFound }
        guard note.utf8.count <= 16000 else { throw GoalLibraryError.textTooLong }
        let annotation = GoalAnnotation(goalID: goalID, createdAt: now, alignment: alignment,
                                        note: note, observation: observation, activityID: activityID, originalJudgment: originalJudgment)
        annotations.append(annotation)
        return annotation
    }

    public mutating func updateAnnotation(id: UUID, alignment: Alignment, note: String) throws {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { throw GoalLibraryError.annotationNotFound }
        guard note.utf8.count <= 16000 else { throw GoalLibraryError.textTooLong }
        annotations[index].alignment = alignment
        annotations[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fills a missing original answer only from the exact activity entry the example came from.
    /// A user's label is never used to infer what Jev said.
    @discardableResult public mutating func restoreOriginalJudgments(_ retained: [UUID: RetainedJudgment]) -> Int {
        var restored = 0
        for index in annotations.indices where annotations[index].originalJudgment == nil {
            guard let activityID = annotations[index].activityID, let match = retained[activityID],
                  match.observationID == annotations[index].observation.id else { continue }
            annotations[index].originalJudgment = match.judgment; restored += 1
        }
        return restored
    }

    public mutating func removeAnnotation(_ id: UUID) throws {
        guard annotations.contains(where: { $0.id == id }) else { throw GoalLibraryError.annotationNotFound }
        annotations.removeAll { $0.id == id }
    }

    public func annotations(for goalID: UUID) -> [GoalAnnotation] {
        annotations.filter { $0.goalID == goalID }.sorted(by: Self.newestFirst)
    }

    /// Matching chooses examples, not an unconditional app or website permission.
    /// Known workspace conflicts outrank all generic app/domain similarities.
    public func relevantNotes(for goalID: UUID, observation: Observation, limit: Int = 6) -> [String] {
        guard goals.contains(where: { $0.id == goalID }), limit > 0 else { return [] }
        let ranked = annotations.filter { $0.goalID == goalID && $0.alignment != .unclear }
            .compactMap { annotation -> (GoalAnnotation, Int)? in
                let rank = Self.relevance(annotation.observation, observation)
                return rank > 0 ? (annotation, rank) : nil
            }.sorted { $0.1 == $1.1 ? Self.newestFirst($0.0, $1.0) : $0.1 > $1.1 }
        var notes: [String] = []; var bytes = 0
        for (annotation, _) in ranked.prefix(min(limit, 6)) {
            let note = Self.promptExample(annotation)
            guard bytes + note.utf8.count <= 12000 else { break }
            notes.append(note); bytes += note.utf8.count
        }
        return notes
    }

    public func validate() throws {
        let ids = Set(goals.map(\.id))
        guard ids.count == goals.count, Set(annotations.map(\.id)).count == annotations.count,
              activeGoalID.map({ ids.contains($0) }) ?? true else { throw GoalLibraryError.invalidLibrary }
        for goal in goals {
            guard !goal.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  goal.createdAt.timeIntervalSince1970.isFinite, goal.updatedAt.timeIntervalSince1970.isFinite else {
                throw GoalLibraryError.invalidLibrary
            }
            try Self.checkText(title: goal.title, goal: goal.goal, context: goal.context)
        }
        for annotation in annotations {
            guard ids.contains(annotation.goalID), annotation.createdAt.timeIntervalSince1970.isFinite,
                  annotation.note.utf8.count <= 16000,
                  annotation.observation == GoalAnnotation.boundedObservation(annotation.observation) else {
                throw GoalLibraryError.invalidLibrary
            }
        }
    }

    private static func checkText(title: String, goal: String, context: String) throws {
        guard title.utf8.count <= 300, goal.utf8.count <= 16000, context.utf8.count <= 16000 else {
            throw GoalLibraryError.textTooLong
        }
    }

    private static func newestFirst(_ lhs: GoalAnnotation, _ rhs: GoalAnnotation) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.createdAt > rhs.createdAt
    }

    private static func canonical(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    private static func host(_ text: String) -> String? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    private static func relevance(_ saved: Observation, _ current: Observation) -> Int {
        let sameApp = !saved.bundleID.isEmpty && saved.bundleID == current.bundleID
        var projectMatch = false
        if saved.activeWorkspace != nil || current.activeWorkspace != nil {
            guard sameApp, let first = saved.activeWorkspace, let second = current.activeWorkspace,
                  !canonical(first.project).isEmpty, canonical(first.project) == canonical(second.project) else { return 0 }
            projectMatch = true
            if !canonical(first.thread).isEmpty, canonical(first.thread) == canonical(second.thread) { return 400 }
        }
        if !saved.url.isEmpty, saved.url == current.url { return 300 }
        if projectMatch { return 250 }
        if sameApp, let firstHost = host(saved.url), firstHost == host(current.url) { return 100 }
        if sameApp, saved.url.isEmpty, current.url.isEmpty {
            let title = canonical(saved.windowTitle)
            if !title.isEmpty, title != canonical(saved.appName), title == canonical(current.windowTitle),
               title != canonical(current.appName) { return 50 }
        }
        return 0
    }

    private static func promptExample(_ annotation: GoalAnnotation) -> String {
        let observation = annotation.observation
        let excerpt = [observation.selectedText, observation.accessibilityText,
                       observation.browserText, observation.ocrText].filter { !$0.isEmpty }.joined(separator: "\n")
        var noteBudget = 1200; var excerptBudget = 700; var identityBudget = 600
        while true {
            let fields: [String: String] = [
                "scope": "User-reviewed example for this saved goal and captured context only. Compare the current context; this is not an unconditional allowance or ban for an app, domain, or different project.",
                "alignment": annotation.alignment.rawValue,
                "user_note": boundedText(annotation.note, bytes: noteBudget),
                "app": boundedText(observation.appName, bytes: min(identityBudget, 100)),
                "bundle_id": boundedText(observation.bundleID, bytes: min(identityBudget, 200)),
                "project": boundedText(observation.activeWorkspace?.project ?? "", bytes: min(identityBudget, 300)),
                "thread": boundedText(observation.activeWorkspace?.thread ?? "", bytes: min(identityBudget, 400)),
                "url": boundedText(observation.url, bytes: identityBudget),
                "title": boundedText(observation.tabTitle.isEmpty ? observation.windowTitle : observation.tabTitle, bytes: min(identityBudget, 300)),
                "captured_excerpt": boundedText(excerpt, bytes: excerptBudget)
            ]
            // String-only values are always JSON serializable. Escaping keeps quoted
            // page instructions inside their evidence fields instead of prompt structure.
            guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            if data.count <= 3000 { return text }
            noteBudget /= 2; excerptBudget /= 2; identityBudget /= 2
        }
    }
}

/// GUI-owned persistence. A corrupt or unreadable existing file is never replaced.
public struct GoalLibraryFileStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> GoalLibrary? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        catch { throw GoalLibraryError.corruptFile }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let library = try decoder.decode(GoalLibrary.self, from: data)
            try library.validate()
            return library
        } catch { throw GoalLibraryError.corruptFile }
    }

    /// The presence of even an empty library marks initial import as complete.
    // TEMP-COMPAT 2026-09-22: imports the saved goal/context for installations from
    // before goal libraries. Keep until every supported installation has a library
    // file; then delete loadOrMigrate, its preference-import caller, and migration-only tests.
    public func loadOrMigrate(goal: String, context: String, at now: Date = Date()) throws -> GoalLibrary {
        if let saved = try load() { return saved }
        var library = GoalLibrary()
        if !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let suggestedTitle = goal.components(separatedBy: CharacterSet(charactersIn: ",\n")).first ?? goal
            try library.saveGoal(title: String(suggestedTitle.prefix(40)), goal: goal, context: context, at: now)
        }
        try save(library)
        return library
    }

    public func save(_ library: GoalLibrary) throws {
        _ = try load() // Recheck disk, including corruption introduced after startup.
        try library.validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
