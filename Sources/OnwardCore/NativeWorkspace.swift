import Foundation

/// Labels collected only below T3 Code's named thread-breadcrumb landmark.
/// Sidebar labels and conversation text must never be passed into this accumulator.
public struct NativeWorkspaceBreadcrumb {
    private var projects = Set<String>()
    private var threads = Set<String>()

    public init() {}

    public static func isRoot(bundleID: String, role: String, labels: [String]) -> Bool {
        bundleID == "com.t3tools.t3code" && role == "AXGroup"
            && labels.contains("Thread breadcrumb")
    }

    public mutating func record(role: String, labels: [String]) {
        guard role == "AXButton" || role == "AXPopUpButton" else { return }
        for label in labels {
            if let project = suffix(of: label, after: "New thread in ", limit: 300) {
                projects.insert(project)
            }
            if let thread = suffix(of: label, after: "Thread actions for ", limit: 600) {
                threads.insert(thread)
            }
        }
    }

    public var evidence: ActiveWorkspaceEvidence? {
        guard projects.count == 1, threads.count == 1,
              let project = projects.first, let thread = threads.first else { return nil }
        return ActiveWorkspaceEvidence(project: project, thread: thread, source: "macOS Accessibility",
            evidence: "Thread breadcrumb landmark: New thread in \(project) / Thread actions for \(thread)")
    }

    private func suffix(of label: String, after prefix: String, limit: Int) -> String? {
        guard label.hasPrefix(prefix) else { return nil }
        let suffix = String(label.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty, suffix.utf8.count <= limit else { return nil }
        return suffix
    }
}

public struct NativeTextRegion {
    public var text: String
    public var frame: CGRect
    public init(text: String, frame: CGRect) { self.text = text; self.frame = frame }
}

public enum NativeWorkspaceCoverage {
    /// AX positions share the desktop's top-left coordinate space. Require readable
    /// text below the main-pane breadcrumb, not sidebar or header labels.
    public static func hasSufficientText(breadcrumb: CGRect?, window: CGRect?,
                                         regions: [NativeTextRegion], traversalComplete: Bool) -> Bool {
        guard traversalComplete, let breadcrumb, let window,
              valid(breadcrumb), valid(window), window.contains(breadcrumb) else { return false }
        var seen = Set<String>()
        let characters = regions.reduce(0) { count, region in
            guard valid(region.frame), window.contains(region.frame),
                  region.frame.minX >= breadcrumb.minX,
                  region.frame.minY >= breadcrumb.maxY else { return count }
            let text = region.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(text).inserted else { return count }
            return count + text.count
        }
        return characters >= 300
    }

    private static func valid(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }
}
