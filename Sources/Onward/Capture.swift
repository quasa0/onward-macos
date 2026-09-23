import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import ImageIO
import OnwardCore

enum AXRead {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    static func element(_ owner: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(owner, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func text(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let s = value as? NSAttributedString { return s.string }
        if let n = value as? NSNumber { return n.stringValue }
        if let u = value as? URL { return u.absoluteString }
        return ""
    }
    static func focusedWindow(pid: Int32) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        return element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
    }
    @discardableResult static func capture(pid: Int32, into result: inout Observation) -> Bool {
        guard AXIsProcessTrusted() else { result.warnings.append("Accessibility permission is needed for app text."); return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        let activation = NativeAccessibility.requestIfSupported(app: app, pid: pid)
        if activation.attempted, let error = activation.errorCode {
            result.warnings.append("Native app text could not be activated (Accessibility \(error)).")
        }
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else {
            result.warnings.append("This app did not expose a focused window to Accessibility."); return false
        }
        result.windowTitle = text(value(window, kAXTitleAttribute))
        let focused = element(app, kAXFocusedUIElementAttribute)
        if let focused, text(value(focused, kAXSubroleAttribute)) != "AXSecureTextField" {
            result.focusedElement = [text(value(focused, kAXRoleAttribute)), text(value(focused, kAXTitleAttribute))].filter { !$0.isEmpty }.joined(separator: ": ")
            result.selectedText = boundedText(text(value(focused, kAXSelectedTextAttribute)), bytes: 3000)
        }
        var queue: [(AXUIElement, Int, CFHashCode?)] = [(window, 0, nil)]
        if let focused { queue.insert((focused, 0, nil), at: 0) }
        var seen = Set<CFHashCode>(); var lines: [String] = []; var count = 0; var index = 0
        var breadcrumbSeen: [CFHashCode: Set<CFHashCode>] = [:]
        var breadcrumbs: [CFHashCode: NativeWorkspaceBreadcrumb] = [:]
        var breadcrumbFrames: [CFHashCode: CGRect] = [:]
        var textRegions: [NativeTextRegion] = []
        var windowFrame: CGRect?
        var traversalComplete = true
        let deadline = Date().addingTimeInterval(1.2)
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                     kAXValueAttribute, kAXHelpAttribute, kAXChildrenAttribute,
                     kAXPositionAttribute, kAXSizeAttribute] as CFArray
        while index < queue.count && index < 650 && count < 16000 && Date() < deadline {
            let (node, depth, ancestorBreadcrumb) = queue[index]; index += 1
            let nodeID = CFHash(node)
            let firstVisit = seen.insert(nodeID).inserted
            let firstScopedVisit = ancestorBreadcrumb.map { breadcrumbSeen[$0, default: []].insert(nodeID).inserted } ?? false
            // A focused element can be visited before its landmark ancestor. Revisit
            // it once within that scope so focused breadcrumb buttons remain usable.
            guard firstVisit || firstScopedVisit else { continue }
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(node, names, [], &raw) == .success,
                  let values = raw as? [Any], values.count == 9 else { traversalComplete = false; continue }
            let role = text(values[0]); let subrole = text(values[1])
            if subrole == "AXSecureTextField" { continue }
            let frame = NativeAccessibility.frame(position: values[7], size: values[8])
            if CFEqual(node, window) { windowFrame = frame }
            var parts = [String](); var used = Set<String>()
            for item in values[2...5] {
                let s = boundedText(text(item).trimmingCharacters(in: .whitespacesAndNewlines), bytes: 2500)
                if !s.isEmpty && used.insert(s).inserted { parts.append(s) }
            }
            var breadcrumb = ancestorBreadcrumb
            if NativeWorkspaceBreadcrumb.isRoot(bundleID: result.bundleID, role: role, labels: parts) {
                breadcrumb = nodeID
                breadcrumbFrames[nodeID] = frame
            }
            if let breadcrumb {
                breadcrumbs[breadcrumb, default: NativeWorkspaceBreadcrumb()].record(role: role, labels: parts)
            }
            if firstVisit, !parts.isEmpty {
                let line = "\(role.replacingOccurrences(of: "AX", with: "")): \(parts.joined(separator: " | "))"
                lines.append(line); count += line.utf8.count
                if breadcrumb == nil, let frame, ["AXStaticText", "AXTextArea", "AXTextField"].contains(role) {
                    textRegions.append(NativeTextRegion(text: parts.joined(separator: " "), frame: frame))
                }
            }
            if let children = values[6] as? [AXUIElement], !children.isEmpty {
                if depth < 32 {
                    queue.append(contentsOf: children.prefix(180).map { ($0, depth + 1, breadcrumb) })
                    if children.count > 180 { traversalComplete = false }
                } else { traversalComplete = false }
            }
        }
        let workspaceCandidates = breadcrumbs.compactMap { id, breadcrumb in breadcrumb.evidence.map { (id, $0) } }
        if workspaceCandidates.count == 1 { result.activeWorkspace = workspaceCandidates[0].1 }
        result.accessibilityText = boundedText(lines.joined(separator: "\n"), bytes: 16000)
        if !result.accessibilityText.isEmpty { result.sources.append("Accessibility") }
        if index < queue.count || count >= 16000 { traversalComplete = false }
        if !traversalComplete { result.warnings.append("Accessibility text was bounded or partly unavailable; local OCR can fill gaps.") }
        // Known active context plus readable native content makes an image redundant.
        // Sparse or unsupported trees still use the user's local OCR setting below.
        guard workspaceCandidates.count == 1 else { return false }
        return NativeWorkspaceCoverage.hasSufficientText(breadcrumb: breadcrumbFrames[workspaceCandidates[0].0],
            window: windowFrame, regions: textRegions, traversalComplete: traversalComplete)
    }
}

// NSAppleScript is main-thread-only. AX traversal and Vision stay off the main actor.
@MainActor enum BrowserCapture {
    static let chromium = ["net.imput.helium", "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser"]
    typealias Identity = BrowserTabIdentity
    struct MetadataFailure: Error { var number: Int }
    static func metadata(bundleID id: String) throws -> Identity? {
        guard chromium.contains(id) || id == "com.apple.Safari" else { return nil }
        let tab = id == "com.apple.Safari" ? "current tab of front window" : "active tab of front window"
        let title = id == "com.apple.Safari" ? "name" : "title"
        // Chromium's scripting dictionary exposes a unique tab ID. Safari's tab index is not stable.
        let tabIDRead = id == "com.apple.Safari" ? "" : "try\nset stableTabID to (id of \(tab)) as text\nend try"
        let script = """
        with timeout of 2 seconds
          tell application id "\(id)"
            if (count of windows) is 0 then return {"", "", ""}
            set stableTabID to ""
            \(tabIDRead)
            return {\(title) of \(tab), URL of \(tab), stableTabID}
          end tell
        end timeout
        """
        var error: NSDictionary?
        let reply = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            throw MetadataFailure(number: error[NSAppleScript.errorNumber] as? Int ?? 0)
        }
        guard let reply, reply.numberOfItems == 3 else { throw MetadataFailure(number: -1) }
        return Identity(title: reply.atIndex(1)?.stringValue ?? "", url: reply.atIndex(2)?.stringValue ?? "", tabID: reply.atIndex(3)?.stringValue)
    }
    @discardableResult static func capture(into observation: inout Observation, pageText: Bool) -> Identity? {
        let id = observation.bundleID
        let identity: Identity
        do {
            guard let current = try metadata(bundleID: id) else { return nil }
            identity = current
            observation.tabTitle = identity.title; observation.url = identity.url; observation.browserTabID = identity.tabID
            if !observation.url.isEmpty { observation.sources.append("Browser tab") }
        } catch {
            let number = (error as? MetadataFailure)?.number ?? -1
            observation.warnings.append(number == -1743 ? "Allow Onward to read \(observation.appName) in System Settings → Privacy & Security → Automation." : "Browser tab metadata unavailable (Apple events \(number)).")
            return nil
        }
        guard pageText, !observation.url.isEmpty else { return identity }
        // Prefer the optional CDP companion only when it matches this exact current URL.
        if let companion = companionSnapshot(bundleID: id), companion.url == identity.url, companion.title == identity.title {
            observation.browserText = boundedText(companion.text, bytes: 18000)
            observation.sources.append("Browser AX / DOM")
            observation.warnings.append(contentsOf: companion.warnings)
            return identity
        }
        let tab = id == "com.apple.Safari" ? "current tab of front window" : "active tab of front window"
        let js = "JSON.stringify({text:(document.body?.innerText||'').slice(0,18000),selection:String(getSelection())})"
        let command = id == "com.apple.Safari" ? "do JavaScript \(quote(js)) in \(tab)" : "execute \(tab) javascript \(quote(js))"
        let source = "with timeout of 2 seconds\ntell application id \"\(id)\" to return \(command)\nend timeout"
        var error: NSDictionary?
        let body = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        if let body, let data = body.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            observation.browserText = boundedText(object["text"] ?? "", bytes: 18000)
            if observation.selectedText.isEmpty { observation.selectedText = boundedText(object["selection"] ?? "", bytes: 3000) }
            if !observation.browserText.isEmpty { observation.sources.append("Browser page text") }
        } else if error != nil {
            observation.warnings.append("For more browser text, enable View → Developer → Allow JavaScript from Apple Events, or install the companion extension. Accessibility and local OCR still work.")
        }
        return identity
    }
    private static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    struct Companion: Decodable { var capturedAt: Double; var title: String; var url: String; var text: String; var warnings: [String] }
    private static func companionSnapshot(bundleID: String) -> Companion? {
        let file = AppStorage.directory.appendingPathComponent("browser-\(bundleID).json")
        guard let data = try? Data(contentsOf: file), data.count < 250_000,
              let snapshot = try? JSONDecoder().decode(Companion.self, from: data),
              abs(Date().timeIntervalSince1970 - snapshot.capturedAt) < 8 else { return nil }
        return snapshot
    }
}

enum CaptureEngine {
    enum Failure: LocalizedError {
        case surfaceChanged
        var errorDescription: String? { "The focused app, window, or tab changed during capture. Waiting for a stable view." }
    }
    struct Result: Sendable { let observation: Observation; let screenshotJPEG: Data? }
    /// `reuseScreenshotFingerprint` skips an extra window image when native text proves the
    /// surface is unchanged; the caller keeps the image it already holds for that fingerprint.
    static func capture(pid: Int32, name: String, bundleID: String, ocr: Bool, pageText: Bool,
                        screenshot: Bool = false, reuseScreenshotFingerprint: String? = nil) async throws -> Result {
        let start = Date()
        let initialWindow = AXRead.focusedWindow(pid: pid)
        let initialTitle = initialWindow.map { AXRead.text(AXRead.value($0, kAXTitleAttribute)) }
        var observation = Observation()
        observation.pid = pid; observation.appName = name; observation.bundleID = bundleID
        observation.idleSeconds = SystemActivity.idleSeconds
        let initialTab = await BrowserCapture.capture(into: &observation, pageText: pageText)
        let nativeTextIsSufficient = AXRead.capture(pid: pid, into: &observation)
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        // Same-title windows are common (two browser windows, two documents). The AX focused
        // window's frame identifies the actual one; title alone is a weaker fallback.
        let axFrame = initialWindow.flatMap { window -> CGRect? in
            guard let position = AXRead.value(window, kAXPositionAttribute), let size = AXRead.value(window, kAXSizeAttribute) else { return nil }
            return NativeAccessibility.frame(position: position, size: size)
        }
        func matchesFrame(_ window: [String: Any]) -> Bool {
            guard let axFrame, let bounds = (window[kCGWindowBounds as String] as? NSDictionary)
                .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return false }
            return abs(bounds.minX - axFrame.minX) <= 2 && abs(bounds.minY - axFrame.minY) <= 2 &&
                abs(bounds.width - axFrame.width) <= 2 && abs(bounds.height - axFrame.height) <= 2
        }
        let titled = observation.windowTitle.isEmpty ? [] : windows.filter { ($0[kCGWindowName as String] as? String) == observation.windowTitle }
        let verified = titled.first(where: matchesFrame) ?? windows.first(where: matchesFrame) ?? (titled.count == 1 ? titled.first : nil)
        let selected = verified ?? titled.first ?? windows.first
        observation.windowID = selected?[kCGWindowNumber as String] as? UInt32
        if observation.windowTitle.isEmpty { observation.windowTitle = selected?[kCGWindowName as String] as? String ?? "" }
        var screenshotJPEG: Data?
        let needsOCR = ocr && !nativeTextIsSufficient
        // Review images must show the focused window, not a same-app guess.
        let wantsScreenshot = screenshot && verified != nil &&
            (needsOCR || reuseScreenshotFingerprint == nil || observation.fingerprint != reuseScreenshotFingerprint)
        if wantsScreenshot || needsOCR {
            if CGPreflightScreenCaptureAccess() {
                do {
                    let image = try await LocalOCR.captureWindow(pid: pid, windowID: observation.windowID)
                    if needsOCR {
                        let evidence = try LocalOCR.recognizeEvidence(image, bundleID: bundleID)
                        observation.ocrText = evidence.text; observation.ocrLayout = evidence.layout
                        if observation.activeWorkspace == nil { observation.activeWorkspace = evidence.activeWorkspace }
                        if !observation.ocrText.isEmpty { observation.sources.append("Local OCR · Apple Vision") }
                    }
                    if wantsScreenshot, observation.fingerprint != reuseScreenshotFingerprint {
                        screenshotJPEG = WindowScreenshot.jpeg(image)
                    }
                } catch { observation.warnings.append("Window image unavailable: \(error.localizedDescription)") }
            } else { observation.warnings.append("Screen Recording permission is needed for local OCR and review screenshots.") }
        }
        // Reject a mixed observation if focus changed while another source was read.
        let finalWindow = AXRead.focusedWindow(pid: pid)
        let finalTitle = finalWindow.map { AXRead.text(AXRead.value($0, kAXTitleAttribute)) }
        let finalTab = initialTab == nil ? nil : (try? await BrowserCapture.metadata(bundleID: bundleID))
        let sameTab: Bool
        if let initialTab { sameTab = finalTab.map { initialTab.isSameTab(as: $0) } ?? false }
        else { sameTab = true }
        let stableBrowserTab = initialTab?.tabID != nil && sameTab
        let sameWindow: Bool
        switch (initialWindow, finalWindow) {
        case (.none, .none): sameWindow = true
        case (.some(let first), .some(let last)): sameWindow = CFEqual(first, last) && (initialTitle == finalTitle || stableBrowserTab)
        default: sameWindow = false
        }
        let sameApp = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
        guard sameApp, sameWindow, sameTab else { throw Failure.surfaceChanged }
        observation.captureMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
        observation.capturedAt = start
        return Result(observation: observation, screenshotJPEG: screenshotJPEG)
    }
}

enum LocalOCR {
    enum Failure: LocalizedError { case noWindow; var errorDescription: String? { "No visible window could be captured." } }
    static func captureWindow(pid: Int32, windowID: UInt32?) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40 }
        guard let windowID, let window = candidates.first(where: { $0.windowID == windowID }) else { throw Failure.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(2.0, 2800 / max(window.frame.width, window.frame.height))
        config.width = max(1, Int(window.frame.width * scale)); config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
    static func recognize(_ image: CGImage) throws -> String {
        try recognizeEvidence(image, bundleID: "").text
    }
    static func recognizeEvidence(_ image: CGImage, bundleID: String) throws -> OCRCaptureEvidence {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["en-US", "de-DE"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation -> OCRTextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRTextLine(text: candidate.string, x: box.minX, y: 1 - box.maxY,
                               width: box.width, height: box.height, confidence: Double(candidate.confidence))
        }
        // Only recognized text is used by Jev. Review screenshots are stored separately on this Mac.
        return OCRLayout.analyze(lines, bundleID: bundleID)
    }
}

/// Encode once off the main actor; keep review images readable but bounded.
enum WindowScreenshot {
    static func jpeg(_ image: CGImage) -> Data? {
        let scale = min(1, 1600 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, resized, [kCGImageDestinationLossyCompressionQuality: 0.76] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
