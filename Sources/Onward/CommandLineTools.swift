import AppKit
import SwiftUI
import OnwardCore

enum CommandLineTools {
    @MainActor static func run(_ arguments: [String]) async {
        do {
            switch arguments.first {
            case "--import-key-from":
                guard arguments.count == 2 else { throw CLIError.message("Provide an env file path.") }
                let content = try String(contentsOfFile: arguments[1], encoding: .utf8)
                guard let line = content.split(separator: "\n").first(where: { $0.hasPrefix("TYPESAFE_API_KEY=") }) else { throw CLIError.message("No TypeSafe key in the specified file.") }
                let key = String(line.dropFirst("TYPESAFE_API_KEY=".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'\r"))
                guard !key.isEmpty else { throw JevError.missingKey }
                try Credentials.save(key)
                print("TypeSafe key saved in macOS Keychain. No key is bundled with the app.")
            case "--smoke-test":
                try await smoke()
            case "--replay-entry":
                guard arguments.count == 2, let id = UUID(uuidString: arguments[1]),
                      let entry = AppStorage.recentEntries().first(where: { $0.id == id }) else {
                    throw CLIError.message("Provide a saved activity entry UUID.")
                }
                guard let key = Credentials.read(), !key.isEmpty else { throw JevError.missingKey }
                let result = try await JevClient().classify(goal: entry.goal, context: "", observation: entry.observation,
                                                          recent: [], corrections: [], key: key)
                var policy = FocusPolicy(); policy.accept(result, at: Date())
                print("Saved observation replay: previous=\(entry.judgment?.alignment.rawValue ?? "none"), current=\(result.alignment.rawValue), p=\(String(format: "%.3f", result.probability)), display=\(policy.status(at: Date()).rawValue)")
            case "--classify-image":
                guard (3...4).contains(arguments.count),
                      let inputImage = NSImage(contentsOfFile: arguments[1]),
                      let image = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw CLIError.message("Provide an existing image path, app bundle ID, and optional repeat count (1–5).")
                }
                let repetitions = arguments.count == 4 ? Int(arguments[3]) ?? 0 : 1
                guard (1...5).contains(repetitions) else { throw CLIError.message("Repeat count must be 1–5.") }
                let defaults = UserDefaults.standard
                guard let goal = defaults.string(forKey: "goal"), !goal.isEmpty else { throw CLIError.message("Set a goal before classifying an image.") }
                guard let key = Credentials.read(), !key.isEmpty else { throw JevError.missingKey }
                let evidence = try LocalOCR.recognizeEvidence(image, bundleID: arguments[2])
                var observation = Observation(); observation.bundleID = arguments[2]
                observation.ocrText = evidence.text; observation.ocrLayout = evidence.layout
                observation.activeWorkspace = evidence.activeWorkspace
                observation.sources = ["Local OCR · user-supplied image"]
                print("Active workspace: \(evidence.activeWorkspace?.project ?? "unresolved") / \(evidence.activeWorkspace?.thread ?? "unresolved")")
                for index in 1...repetitions {
                    let result = try await JevClient().classify(goal: goal, context: defaults.string(forKey: "context") ?? "", observation: observation, recent: [], corrections: [], key: key)
                    print("Image classification \(index): \(result.alignment.rawValue), p=\(String(format: "%.3f", result.probability))")
                }
            case "--capture-once", "--capture-diagnostics":
                guard let app = NSWorkspace.shared.frontmostApplication else { throw CLIError.message("No foreground app.") }
                let observation = try await CaptureEngine.capture(pid: app.processIdentifier, name: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "", ocr: true, pageText: true)
                if arguments.first == "--capture-diagnostics" {
                    let data = try JSONSerialization.data(withJSONObject: [
                        "bundleID": observation.bundleID, "AXCharacters": observation.accessibilityText.count,
                        "OCRCharacters": observation.ocrText.count, "captureMilliseconds": observation.captureMilliseconds,
                        "workspace": observation.activeWorkspace?.project ?? "unresolved",
                        "thread": observation.activeWorkspace?.thread ?? "unresolved",
                        "workspaceSource": observation.activeWorkspace?.source ?? "none",
                        "warnings": observation.warnings
                    ])
                    print(String(decoding: data, as: UTF8.self))
                } else { print(String(data: try AppStorage.encoder.encode(observation), encoding: .utf8)!) }
            case "--render-preview":
                guard (2...6).contains(arguments.count) else { throw CLIError.message("Provide a PNG path, optional view (now/activity/settings/hud/glow), state, theme (light/dark), and dimensions (980x780).") }
                let dimensions = arguments.count > 5 ? arguments[5].split(separator: "x").compactMap { Double($0) } : [980, 780]
                guard dimensions.count == 2, dimensions[0] >= 860, dimensions[1] >= 690,
                      dimensions[0] <= 2000, dimensions[1] <= 2000 else { throw CLIError.message("Preview dimensions must be 860x690 through 2000x2000.") }
                try await renderPreview(to: URL(fileURLWithPath: arguments[1]),
                                        surface: arguments.count > 2 ? arguments[2] : "now",
                                        state: arguments.count > 3 ? arguments[3] : "ready",
                                        dark: arguments.count > 4 && arguments[4] == "dark",
                                        dimensions: NSSize(width: dimensions[0], height: dimensions[1]))
            default: throw CLIError.message("Supported: --import-key-from PATH, --smoke-test, --capture-once, --capture-diagnostics, --replay-entry UUID, --classify-image PATH BUNDLE_ID [REPEATS], --render-preview PATH")
            }
        } catch { fputs("Onward: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor private static func renderPreview(to url: URL, surface: String, state: String, dark: Bool, dimensions: NSSize) async throws {
        // Synthetic, offscreen UI only. No screen capture, classification, or preference changes.
        NSApp.setActivationPolicy(.prohibited)
        let model = ObserverModel(audioEnabled: false); model.stop(publishStatus: false)
        model.goal = ""; model.context = ""; model.entries = []
        let establishedState = state.hasPrefix("checking-") ? String(state.dropFirst("checking-".count)) : state
        model.status = FocusStatus(rawValue: establishedState) ?? .ready
        if state.hasPrefix("checking-") { model.status = .observing }
        model.accessibilityGranted = true; model.screenGranted = true; model.hasKey = true
        if state != "ready" {
            model.goal = "Build Onward’s local OCR capture"
            model.context = "Apple documentation and implementation work support this goal."
            model.isRunning = true; model.startedAt = Date().addingTimeInterval(-754)
            var observation = Observation()
            observation.appName = "Helium"; observation.bundleID = "net.imput.helium"
            observation.windowTitle = "Recognizing text in images | Apple Developer Documentation"
            observation.tabTitle = observation.windowTitle
            observation.url = "https://developer.apple.com/documentation/vision/recognizing-text-in-images"
            observation.accessibilityText = "Use Vision to find and recognize text within images."
            observation.ocrText = "Recognizing text in images. Configure VNRecognizeTextRequest."
            observation.sources = ["Browser tab", "Accessibility", "Local OCR"]
            model.observation = observation
            let alignment: OnwardCore.Alignment = [.drifting, .distracted].contains(model.displayStatus) ? .offGoal : .onGoal
            model.judgment = Judgment(alignment: alignment, probabilities: [alignment.rawValue: 0.94], confidence: 0.94)
            model.entries = [ActivityEntry(goal: model.goal, observation: observation, judgment: model.judgment)]
        }
        let size = surface == "hud" ? NSSize(width: GoalHUD.side, height: GoalHUD.side) : dimensions
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isOpaque = surface != "hud"; window.backgroundColor = surface == "hud" ? .clear : .windowBackgroundColor
        let root: AnyView
        switch surface {
        case "hud": root = AnyView(GoalHUD(model: model))
        case "glow": root = AnyView(ScreenEdgeGlowPreview(status: model.displayStatus))
        case "settings": root = AnyView(Dashboard(model: model, initialSelection: "Settings"))
        case "activity": root = AnyView(Dashboard(model: model, initialSelection: "Activity"))
        case "now": root = AnyView(Dashboard(model: model))
        default: throw CLIError.message("Unknown preview view: \(surface)")
        }
        let view = NSHostingView(rootView: root.environment(\.colorScheme, dark ? .dark : .light))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CLIError.message("Could not allocate preview image.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output: NSBitmapImageRep
        if surface == "glow" {
            // Composite the transparent edge backing separately: draw(_:) clears its
            // own surface, which would otherwise erase a shared preview background.
            let canvas = NSImage(size: size)
            canvas.lockFocus()
            NSColor(white: dark ? 0.08 : 0.96, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            if let glowImage = bitmap.cgImage, let context = NSGraphicsContext.current?.cgContext {
                context.setBlendMode(.normal)
                context.draw(glowImage, in: NSRect(origin: .zero, size: size))
            }
            let title = "\(model.displayStatus.title) · screen-edge glow" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .medium),
                                                           .foregroundColor: dark ? NSColor.white : NSColor.black]
            let textSize = title.size(withAttributes: attributes)
            title.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: size.height / 2), withAttributes: attributes)
            canvas.unlockFocus()
            guard let cgImage = canvas.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CLIError.message("Could not composite glow preview.") }
            output = NSBitmapImageRep(cgImage: cgImage)
        } else { output = bitmap }
        guard let data = output.representation(using: .png, properties: [:]) else { throw CLIError.message("Could not encode preview image.") }
        try data.write(to: url, options: .atomic)
        print("Rendered \(surface), \(state), \(dark ? "dark" : "light"): \(url.path)")
    }
    @MainActor private static func smoke() async throws {
        try smokeEdgeGlow()
        for resource in WarningSoundChoice.allCases.map(\.resourceName) + TimeCueSoundChoice.allCases.map(\.resourceName) {
            _ = try SoundPlayer.load(resourceName: resource)
        }
        print("PASS all \(WarningSoundChoice.allCases.count) warning sounds and \(TimeCueSoundChoice.allCases.count) time cues decode (silent validation)")
        async let timerCheck: Void = smokeTimeCueTimer()
        let presentationModel = ObserverModel(audioEnabled: false); presentationModel.stop(publishStatus: false)
        for established in [FocusStatus.focused, .drifting, .distracted] {
            presentationModel.status = established
            for pending in [FocusStatus.observing, .unclear, .paused, .idle, .unavailable] {
                presentationModel.status = pending
                guard presentationModel.displayStatus == established else {
                    throw CLIError.message("Operational state replaced the established display color.")
                }
            }
        }
        print("PASS installed observer display retains green/yellow/red through checking and interruptions")
        let size = NSSize(width: 1000, height: 180)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        ("Onward local OCR works 12345" as NSString).draw(at: NSPoint(x: 30, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 38), .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CLIError.message("Could not make OCR fixture.") }
        let text = try LocalOCR.recognize(cgImage)
        guard text.contains("Onward"), text.contains("12345") else { throw CLIError.message("Local Vision OCR failed: \(text)") }
        print("PASS local Vision OCR (synthetic image; no network used for OCR)")
        guard let key = Credentials.read(), !key.isEmpty else { throw JevError.missingKey }
        let client = JevClient()
        let fixtures: [(String, String, String, Set<OnwardCore.Alignment>)] = [
            ("Xcode", "Onward — Capture.swift", "Implementing local OCR with VNRecognizeTextRequest. Building the macOS observer app.", [.onGoal, .supporting]),
            ("Helium", "Apple Developer — VNRecognizeTextRequest", "Reading documentation on local OCR to implement the observer app.", [.onGoal, .supporting]),
            ("Helium", "Funny cat videos — YouTube", "Watching a compilation of cute cats for entertainment. Unrelated to the app.", [.offGoal]),
            ("Notes", "Grocery list", "Buying potatoes, milk, bananas and coffee. Planning dinner.", [.offGoal]),
            ("Unknown app", "", "", [.unclear])
        ]
        var fixturePolicy = FocusPolicy()
        let fixtureEpoch = Date()
        for (index, fixture) in fixtures.enumerated() {
            let (app, title, body, expected) = fixture
            var observation = Observation(); observation.appName = app; observation.windowTitle = title; observation.accessibilityText = body
            let result = try await client.classify(goal: "Build a macOS focus observer app with local OCR and Jev classification", context: "", observation: observation, recent: [], corrections: [], key: key)
            print("\(expected.contains(result.alignment) ? "PASS" : "FAIL") Jev fixture \(app) / \(title.isEmpty ? "no evidence" : title): \(result.alignment.rawValue), p=\(String(format: "%.3f", result.probability)), \(result.latencyMilliseconds)ms, \(result.model)")
            guard expected.contains(result.alignment) else { throw CLIError.message("Unexpected Jev classification.") }
            let fixtureTime = fixtureEpoch.addingTimeInterval(Double(index) * 10)
            let previousStatus = fixturePolicy.status(at: fixtureTime)
            fixturePolicy.accept(result, at: fixtureTime)
            if result.alignment == .unclear {
                guard fixturePolicy.isHoldingStatus,
                      fixturePolicy.status(at: fixtureTime) == previousStatus,
                      fixturePolicy.status(at: fixtureTime.addingTimeInterval(20)) == previousStatus,
                      fixturePolicy.offGoalDuration(at: fixtureTime.addingTimeInterval(20)) == fixturePolicy.offGoalDuration(at: fixtureTime) else {
                    throw CLIError.message("Uncertain Jev response changed the previous color or advanced its timer.")
                }
                print("PASS uncertain Jev response preserves previous color and freezes distraction timer")
            }
        }
        for (header, body, expected) in [
            ("Playground / macOS focus observer", "Implementing menu bar indicators and local OCR for the macOS observer.", OnwardCore.Alignment.offGoal),
            ("Project Atlas / Fix sign-in", "Debugging the authentication failure in Project Atlas.", OnwardCore.Alignment.onGoal)
        ] {
            var observation = Observation(); observation.appName = "Coding workspace"; observation.windowTitle = "Workspace"
            observation.ocrText = "\(header)\nSidebar: Project Atlas / Fix sign-in; Project Beacon / Redesign; Playground / macOS focus observer.\nMain conversation: \(body)"
            let result = try await client.classify(goal: "Work only on Project Atlas. Project Beacon and Playground are out of scope.", context: "", observation: observation, recent: [], corrections: [], key: key)
            guard result.alignment == expected || (expected == .onGoal && result.alignment == .supporting) else {
                throw CLIError.message("Active-project fixture failed: \(header) classified as \(result.alignment.rawValue).")
            }
            print("PASS selected-project fixture: \(header), \(result.alignment.rawValue), p=\(String(format: "%.3f", result.probability))")
        }
        for (project, thread, body, expected) in [
            ("Playground", "macOS focus monitor", "The user says the Project Atlas goal turns green while this Playground conversation is open. Fixing the focus monitor to support their productivity. Background agents are working on Project Atlas.", OnwardCore.Alignment.offGoal),
            ("Project Atlas", "Fix sign-in", "Implementing the Project Atlas authentication fix. An earlier focus monitor report incorrectly mentioned Playground.", OnwardCore.Alignment.onGoal)
        ] {
            var observation = Observation(); observation.appName = "T3 Code"; observation.bundleID = "com.t3tools.t3code"
            observation.windowTitle = "T3 Code"
            observation.activeWorkspace = ActiveWorkspaceEvidence(project: project, thread: thread, source: "Accessibility", evidence: "Thread breadcrumb")
            observation.accessibilityText = "Sidebar: Project Atlas; Project Beacon; Playground.\nMain conversation: \(body)"
            let result = try await client.classify(goal: "Project Atlas, not Project Beacon, not Playground, only Project Atlas work", context: "", observation: observation, recent: [], corrections: [], key: key)
            guard result.alignment == expected || (expected == .onGoal && result.alignment == .supporting) else {
                throw CLIError.message("Native selected-workspace fixture failed: \(project) classified as \(result.alignment.rawValue).")
            }
            print("PASS native workspace fixture: \(project), \(result.alignment.rawValue), p=\(String(format: "%.3f", result.probability))")
        }
        try await timerCheck
        print("PASS smoke test: edge glow + sound library + clock-aligned timer + retained display + OCR + authenticated Jev + nine classifications")
    }

    @MainActor private static func smokeTimeCueTimer() async throws {
        // Exercise real run-loop timers without playing audio or changing preferences.
        var cues: [Date] = []
        let controller = TimeCueController { cues.append(Date()) }
        defer { controller.stop() }
        func waitPastNextBoundary() async throws {
            let boundary = TimeCueSchedule.nextBoundary(after: Date(), interval: .fiveSeconds)
            try await Task.sleep(nanoseconds: UInt64((max(0, boundary.timeIntervalSinceNow) + 0.65) * 1_000_000_000))
        }
        controller.configure(enabled: true, interval: .fiveSeconds)
        try await waitPastNextBoundary()
        guard cues.count == 1 else { throw CLIError.message("Native time cue did not fire once at the next clock boundary.") }
        controller.setSuspended(true)
        try await waitPastNextBoundary()
        guard cues.count == 1 else { throw CLIError.message("Suspended time cue fired.") }
        controller.setSuspended(false)
        try await waitPastNextBoundary()
        guard cues.count == 2 else { throw CLIError.message("Time cue did not resume at the next clock boundary.") }
        controller.configure(enabled: false, interval: .fiveSeconds)
        try await waitPastNextBoundary()
        guard cues.count == 2 else { throw CLIError.message("Disabled time cue fired.") }
        let lateness = cues.map { $0.timeIntervalSince1970.truncatingRemainder(dividingBy: 5) }
        guard lateness.allSatisfy({ $0 >= 0 && $0 <= 0.5 }) else {
            throw CLIError.message("Native time cue drifted from clock boundaries.")
        }
        print("PASS native time cues: aligned callbacks, suspend/resume, disable; max lateness \(Int((lateness.max() ?? 0) * 1000))ms (silent)")
    }
    @MainActor private static func smokeEdgeGlow() throws {
        let size = NSSize(width: 400, height: 400)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for status in [FocusStatus.ready, .observing, .focused, .drifting, .distracted, .paused, .idle, .unavailable, .unclear] {
            let view = ScreenEdgeGlowView(status: status, animated: false)
            window.contentView = view
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            guard !view.acceptsFirstResponder, view.hitTest(.zero) == nil,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw CLIError.message("Edge glow must pass input through and support transparent rendering.")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
            let scale = Double(width) / size.width
            func alpha(_ x: Int, _ y: Int) -> CGFloat { bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1 }
            guard alpha(width / 2, height / 2) == 0 else { throw CLIError.message("Edge glow filled the screen center.") }
            let edgeAlpha = [alpha(1, height / 2), alpha(width - 2, height / 2), alpha(width / 2, 1), alpha(width / 2, height - 2)]
            let active = status == .drifting || status == .distracted
            guard active ? edgeAlpha.allSatisfy({ $0 > 0 }) : edgeAlpha.allSatisfy({ $0 == 0 }) else {
                throw CLIError.message("Glow must cover all four edges only for yellow/red.")
            }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                let inward = alpha(Int(32 * scale), height / 2)
                guard status == .distracted ? inward > 0.03 : inward == 0 else {
                    throw CLIError.message("Red glow must extend farther inward than yellow.")
                }
                guard alpha(Int(60 * scale), height / 2) == 0 else {
                    throw CLIError.message("Edge glow must leave content beyond its narrow perimeter untinted.")
                }
            }
        }
        print("PASS edge glow: four yellow/red edges, wider red, transparent center, no green, click-through renderer (offscreen)")
    }
    enum CLIError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let text) = self { return text }; return nil } }
}

private struct ScreenEdgeGlowPreview: NSViewRepresentable {
    let status: FocusStatus
    func makeNSView(context: Context) -> ScreenEdgeGlowView { ScreenEdgeGlowView(status: status, animated: false) }
    func updateNSView(_ view: ScreenEdgeGlowView, context: Context) { view.update(status: status, animated: false) }
}
