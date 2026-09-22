import Foundation

public struct ActiveWorkspaceEvidence: Codable, Equatable, Sendable {
    public var project: String
    public var thread: String
    public var source: String
    public var evidence: String
    public init(project: String, thread: String, source: String, evidence: String) {
        self.project = project; self.thread = thread; self.source = source; self.evidence = evidence
    }
}

/// Normalized window coordinates, with the origin at the top left.
public struct OCRTextLine: Codable, Equatable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var confidence: Double
    public init(text: String, x: Double, y: Double, width: Double, height: Double, confidence: Double = 1) {
        self.text = text; self.x = x; self.y = y; self.width = width; self.height = height; self.confidence = confidence
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midY: Double { y + height / 2 }
}

public struct OCRLayoutEvidence: Codable, Equatable, Sendable {
    public var source: String
    public var headerText: String
    public var sidebarText: String
    public var mainContentText: String
    public var mainPaneLeft: Double
    public var headerLines: [OCRTextLine]
}

public struct OCRCaptureEvidence: Sendable {
    public var text: String
    public var layout: OCRLayoutEvidence?
    public var activeWorkspace: ActiveWorkspaceEvidence?
}

public enum OCRLayout {
    /// App-specific geometry is deliberately limited to a verified native window layout.
    /// Unknown apps and ambiguous headers keep their ordinary OCR text without a guessed workspace.
    public static func analyze(_ input: [OCRTextLine], bundleID: String) -> OCRCaptureEvidence {
        let lines = input.filter {
            [$0.x, $0.y, $0.width, $0.height, $0.confidence].allSatisfy(\.isFinite)
                && $0.x >= 0 && $0.y >= 0 && $0.width > 0 && $0.height > 0
                && $0.maxX <= 1.01 && $0.maxY <= 1.01 && $0.confidence >= 0.25
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted(by: readingOrder)
        var result = OCRCaptureEvidence(text: joined(lines, budget: 16000))
        guard bundleID == "com.t3tools.t3code",
              let appLabel = lines.first(where: { canonical($0.text) == "t3 code" && $0.x < 0.3 && $0.y < 0.12 }) else { return result }
        let row = lines.filter {
            $0.x > appLabel.maxX + 0.035 && $0.x >= 0.18 && $0.x < 0.65
                && abs($0.midY - appLabel.midY) <= max($0.height, appLabel.height) * 0.8
        }.sorted { $0.x < $1.x }
        guard let first = row.first else { return result }
        let rawProject: String, rawThread: String, headerLines: [OCRTextLine]
        if let separator = first.text.range(of: #"\s+/\s+"#, options: .regularExpression) {
            rawProject = String(first.text[..<separator.lowerBound])
            rawThread = String(first.text[separator.upperBound...])
            headerLines = [first]
        } else {
            guard row.count >= 2, row[1].x - first.maxX < 0.07 else { return result }
            rawProject = first.text; rawThread = row[1].text; headerLines = Array(row.prefix(2))
        }
        let paneLeft = max(0, first.x - 0.02)
        let headerBottom = headerLines.map(\.maxY).max() ?? first.maxY
        let sidebar = lines.filter { $0.y > headerBottom + 0.005 && $0.maxX <= paneLeft + 0.005 }
        // Corroboration prevents a lone toolbar button or an OCR fragment from becoming a project.
        // A short leading badge glyph may be OCR'd with the project in either place.
        let projectCandidates = sidebar.compactMap { corroboratedProject(rawProject, sidebar: $0.text) }
        guard let project = projectCandidates.min(by: { $0.count < $1.count }), !project.isEmpty else { return result }
        let thread = rawThread.trimmingCharacters(in: .whitespacesAndNewlines)
        guard thread.count >= 2, thread.count <= 200, !thread.contains("…") else { return result }
        let header = headerLines.map(\.text).joined(separator: " / ")
        let main = lines.filter { $0.y > headerBottom + 0.005 && $0.x >= paneLeft }
        result.layout = OCRLayoutEvidence(source: "Apple Vision · T3 Code window geometry",
            headerText: boundedText(header, bytes: 1000), sidebarText: joined(sidebar, budget: 3500),
            mainContentText: joined(main, budget: 12000), mainPaneLeft: paneLeft, headerLines: headerLines)
        result.activeWorkspace = ActiveWorkspaceEvidence(project: boundedText(project, bytes: 300),
            thread: boundedText(thread, bytes: 600), source: "Apple Vision · main-pane breadcrumb",
            evidence: "Top-row main-pane breadcrumb; project corroborated in the separate left sidebar. " + boundedText(header, bytes: 1000))
        return result
    }

    private static func corroboratedProject(_ header: String, sidebar: String) -> String? {
        let first = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = sidebar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard first.count <= 100, second.count <= 100 else { return nil }
        let a = canonical(first), b = canonical(second)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        if a == b { return first }
        if a.hasSuffix(" " + b), a.count - b.count <= 3 { return second }
        if b.hasSuffix(" " + a), b.count - a.count <= 3 { return first }
        return nil
    }
    private static func canonical(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func readingOrder(_ first: OCRTextLine, _ second: OCRTextLine) -> Bool {
        let firstRow = Int((first.midY / 0.015).rounded()), secondRow = Int((second.midY / 0.015).rounded())
        return firstRow != secondRow ? firstRow < secondRow : first.x < second.x
    }
    private static func joined(_ lines: [OCRTextLine], budget: Int) -> String {
        boundedText(lines.map(\.text).joined(separator: "\n"), bytes: budget)
    }
}
