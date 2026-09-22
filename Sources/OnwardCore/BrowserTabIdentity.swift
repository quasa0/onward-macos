public struct BrowserTabIdentity: Equatable, Sendable {
    public var title: String
    public var url: String
    public var tabID: String?

    public init(title: String, url: String, tabID: String? = nil) {
        self.title = title; self.url = url
        self.tabID = tabID.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func isSameTab(as other: BrowserTabIdentity) -> Bool {
        guard url == other.url else { return false }
        switch (tabID, other.tabID) {
        case (.some(let first), .some(let last)): return first == last
        // Safari and browsers without a stable scripting ID need a conservative title check.
        case (.none, .none): return title == other.title
        default: return false
        }
    }
}
