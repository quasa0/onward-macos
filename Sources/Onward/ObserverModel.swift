import AppKit
import ApplicationServices
import Combine
import UserNotifications
import ServiceManagement
import OnwardCore

@MainActor final class ObserverModel: ObservableObject {
    @Published var goal = UserDefaults.standard.string(forKey: "goal") ?? ""
    @Published var context = UserDefaults.standard.string(forKey: "context") ?? ""
    @Published var isRunning = false
    @Published var status: FocusStatus = .ready {
        didSet {
            if status == .observing { policy.suspend(at: Date()) }
            if !policy.isHoldingStatus {
                presentation.update(status: status, offGoalSeconds: Int(policy.offGoalDuration(at: Date())))
            }
            guard status != oldValue else { return }
            statusTransitions.append(["timestamp": Date().timeIntervalSince1970,
                                      "from": oldValue.rawValue, "to": status.rawValue])
            if statusTransitions.count > 12 { statusTransitions.removeFirst(statusTransitions.count - 12) }
        }
    }
    @Published var observation: Observation?
    @Published var judgment: Judgment?
    @Published var entries = AppStorage.recentEntries()
    @Published var error: String?
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var screenGranted = CGPreflightScreenCaptureAccess()
    @Published var notificationsGranted = false
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var notificationError: String?
    @Published var hasKey = false
    @Published var requestCount = 0
    @Published var inputTokens = 0
    @Published private(set) var lastRequestData: Data?
    @Published var startedAt: Date?
    @Published var now = Date()
    @Published var ocrEnabled = UserDefaults.standard.object(forKey: "ocrEnabled") as? Bool ?? true { didSet { preferenceChanged("ocrEnabled", ocrEnabled) } }
    @Published var browserTextEnabled = UserDefaults.standard.object(forKey: "browserTextEnabled") as? Bool ?? true { didSet { preferenceChanged("browserTextEnabled", browserTextEnabled) } }
    @Published var showHUD = UserDefaults.standard.object(forKey: "showHUD") as? Bool ?? true { didSet { UserDefaults.standard.set(showHUD, forKey: "showHUD") } }
    @Published var showScreenGlow = UserDefaults.standard.object(forKey: "showScreenGlow") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showScreenGlow, forKey: "showScreenGlow") }
    }
    @Published var soundEnabled = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true { didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") } }
    @Published var warningSound = WarningSoundChoice(rawValue: UserDefaults.standard.string(forKey: "warningSound") ?? "") ?? .lowWarning {
        didSet { UserDefaults.standard.set(warningSound.rawValue, forKey: "warningSound") }
    }
    @Published var warningVolume = SoundPlayer.savedVolume("warningVolume", fallback: 1) {
        didSet { UserDefaults.standard.set(warningVolume, forKey: "warningVolume") }
    }
    @Published var timeCueEnabled = UserDefaults.standard.bool(forKey: "timeCueEnabled") {
        didSet { UserDefaults.standard.set(timeCueEnabled, forKey: "timeCueEnabled"); configureTimeCues() }
    }
    @Published var timeCueInterval = TimeCueInterval(rawValue: UserDefaults.standard.object(forKey: "timeCueInterval") as? Int ?? 15) ?? .fifteenSeconds {
        didSet { UserDefaults.standard.set(timeCueInterval.rawValue, forKey: "timeCueInterval"); configureTimeCues() }
    }
    @Published var timeCueSound = TimeCueSoundChoice(rawValue: UserDefaults.standard.string(forKey: "timeCueSound") ?? "") ?? .tick {
        didSet { UserDefaults.standard.set(timeCueSound.rawValue, forKey: "timeCueSound") }
    }
    @Published var timeCueVolume = SoundPlayer.savedVolume("timeCueVolume", fallback: 0.25) {
        didSet { UserDefaults.standard.set(timeCueVolume, forKey: "timeCueVolume") }
    }
    @Published private(set) var soundError: String?
    @Published var saveHistory = UserDefaults.standard.object(forKey: "saveHistory") as? Bool ?? true { didSet { UserDefaults.standard.set(saveHistory, forKey: "saveHistory") } }
    @Published var redAfter = UserDefaults.standard.object(forKey: "redAfter") as? Double ?? 45 { didSet { UserDefaults.standard.set(redAfter, forKey: "redAfter"); policy.redAfter = redAfter } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var apiKey = ""
    private let client = JevClient()
    private var policy = FocusPolicy()
    private var presentation = FocusPresentation()
    private var timer: Timer?
    private var timeCueController: TimeCueController?
    private var observers: [NSObjectProtocol] = []
    private var axObserver: AXObserver?
    private var observedPID: Int32 = 0
    private var captureTask: Task<Void, Never>?
    private var classificationTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var needsCapture = true
    private var revision = UUID()
    private var lastCaptureAt = Date.distantPast
    private var lastRequestedAt = Date.distantPast
    private var lastJudgmentFingerprint = ""
    private var lastJudgmentSurface: FocusSurface?
    private var statusTransitions: [[String: Any]] = []
    private var retryAfter = Date.distantPast
    private var lastAlertAt = Date.distantPast
    private var redAlerted = false
    private var systemSleeping = false
    private var sessionInactive = false
    private var sleeping: Bool { systemSleeping || sessionInactive }
    private var correctionNotes: [String] = []
    private var lastNotificationSettingsRead = Date.distantPast
    private var notificationFailure: String?
    private static let notificationsDisabledMessage = "Notification banners are disabled. Enable Onward in System Settings > Notifications to show reminder banners."

    init(audioEnabled: Bool = true) {
        apiKey = Credentials.read() ?? ""; hasKey = !apiKey.isEmpty
        policy.redAfter = redAfter
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.activeAppChanged() }
        })
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSleepState(systemSleeping: event == NSWorkspace.willSleepNotification) }
            })
        }
        for event in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSleepState(sessionInactive: event == NSWorkspace.sessionDidResignActiveNotification) }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        if audioEnabled {
            timeCueController = TimeCueController(onCue: { [weak self] in self?.playTimeCue(preview: false) })
            configureTimeCues()
        }
        refreshNotifications()
    }
    func start(goal: String, context: String) {
        let nextGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if nextGoal != self.goal || nextContext != self.context || nextGoal.isEmpty { presentation.reset() }
        self.goal = nextGoal
        self.context = nextContext
        UserDefaults.standard.set(self.goal, forKey: "goal"); UserDefaults.standard.set(self.context, forKey: "context")
        resetEvidence()
        guard !self.goal.isEmpty else { isRunning = false; status = .ready; return }
        isRunning = true; startedAt = Date(); status = .observing; error = nil
        activeAppChanged()
    }
    func togglePause() {
        if isRunning { isRunning = false; resetEvidence(); status = .paused }
        else { start(goal: goal, context: context) }
    }
    func stop(publishStatus: Bool = true) {
        isRunning = false; resetEvidence(); timer?.invalidate(); timer = nil
        timeCueController?.stop(); timeCueController = nil
        SoundPlayer.shared.stopAll()
        if publishStatus { publishBrowserStatus() }
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observers = []; detachAX()
    }
    private func resetEvidence() {
        revision = UUID(); classificationTask?.cancel(); classificationTask = nil
        activeRequestID = nil; needsCapture = true
        policy.reset(); judgment = nil; lastJudgmentFingerprint = ""; lastJudgmentSurface = nil; redAlerted = false
        retryAfter = .distantPast; lastRequestedAt = .distantPast
    }
    private func preferenceChanged(_ name: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: name); resetEvidence(); lastCaptureAt = .distantPast
    }
    private func setSleepState(systemSleeping: Bool? = nil, sessionInactive: Bool? = nil) {
        if let systemSleeping { self.systemSleeping = systemSleeping }
        if let sessionInactive { self.sessionInactive = sessionInactive }
        resetEvidence(); lastCaptureAt = .distantPast
        timeCueController?.setSuspended(sleeping)
        if sleeping { SoundPlayer.shared.stopAll() }
        if isRunning { status = sleeping ? .idle : .observing }
    }
    private func tick() {
        now = Date(); accessibilityGranted = AXIsProcessTrusted(); screenGranted = CGPreflightScreenCaptureAccess()
        timeCueController?.setSuspended(sleeping || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow")
        if now.timeIntervalSince(lastNotificationSettingsRead) >= 10 { refreshNotifications() }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" {
            if status != .idle { resetEvidence() }
            if isRunning { status = .idle }
            publishBrowserStatus(); return
        }
        publishBrowserStatus()
        guard isRunning else { return }
        guard !sleeping else { status = .idle; return }
        let idle = SystemActivity.idleSeconds
        guard idle < 300 else {
            if status != .idle { resetEvidence() }
            status = .idle; return
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            holdStatusWhileInspecting(); return
        }
        if Date().timeIntervalSince(lastCaptureAt) >= 4 { capture() }
        updateStatus()
        classifyIfNeeded()
    }
    private func publishBrowserStatus() {
        let timestamp = Date()
        let idle = SystemActivity.idleSeconds
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        var state: [String: Any] = ["enabled": isRunning && !sleeping && browserTextEnabled && status != .idle && idle < 300,
                                    "bundleID": frontmostApp?.bundleIdentifier ?? "",
                                    "accessibilityGranted": accessibilityGranted, "screenCaptureGranted": screenGranted,
                                    "hasGoal": !goal.isEmpty, "running": isRunning,
                                    "focusStatus": status.rawValue, "observerPID": ProcessInfo.processInfo.processIdentifier,
                                    "displayStatus": displayStatus.rawValue,
                                    "holdingPreviousStatus": isHoldingStatus,
                                    "offGoalSeconds": offGoalSeconds,
                                    "statusTransitions": statusTransitions,
                                    "idleSeconds": idle.isFinite ? idle as Any : NSNull(),
                                    "notificationsGranted": notificationsGranted,
                                    "notificationAuthorizationStatus": notificationAuthorizationStatus.rawValue,
                                    "requestCount": requestCount,
                                    "timeCueEnabled": timeCueEnabled,
                                    "timeCueIntervalSeconds": timeCueInterval.rawValue,
                                    "currentError": diagnosticError(error) as Any? ?? NSNull(),
                                    "notificationError": diagnosticError(notificationError) as Any? ?? NSNull(),
                                    "latestCapture": NSNull(), "activeJudgment": NSNull(),
                                    "updatedAt": timestamp.timeIntervalSince1970]
        if let observation {
            let age = max(0, timestamp.timeIntervalSince(observation.capturedAt))
            state["latestCapture"] = ["ageSeconds": age, "captureMilliseconds": observation.captureMilliseconds,
                                      "sourceCount": observation.sources.count, "sources": observation.sources,
                                      "sourceCharacterCounts": ["accessibility": observation.accessibilityText.count,
                                                                "browser": observation.browserText.count,
                                                                "ocr": observation.ocrText.count],
                                      "warningCount": observation.warnings.count,
                                      "hasStableBrowserTabID": observation.browserTabID != nil,
                                      "hasActiveWorkspace": observation.activeWorkspace != nil,
                                      "activeWorkspaceSource": observation.activeWorkspace?.source as Any? ?? NSNull(),
                                      "isForeground": observation.pid == frontmostApp?.processIdentifier] as [String: Any]
            if isRunning, error == nil, policy.status(at: timestamp) != .observing,
               lastJudgmentSurface?.canDisplayJudgment(for: observation, foregroundPID: frontmostApp?.processIdentifier, at: timestamp) == true,
               let judgment {
                state["activeJudgment"] = ["alignment": judgment.alignment.rawValue, "probability": judgment.probability,
                                           "probabilities": judgment.probabilities, "confidence": judgment.confidence,
                                           "matchesLatestContent": observation.fingerprint == lastJudgmentFingerprint] as [String: Any]
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: AppStorage.directory.appendingPathComponent("observer-status.json"), options: .atomic)
        }
    }
    private func diagnosticError(_ value: String?) -> String? {
        guard var value else { return nil }
        // Diagnostics contain operational errors, never session input or credentials.
        for sensitive in [apiKey, goal, context, observation?.url ?? ""] where !sensitive.isEmpty {
            value = value.replacingOccurrences(of: sensitive, with: "[redacted]")
        }
        value = value.replacingOccurrences(of: #"\b[a-zA-Z][a-zA-Z0-9+.-]*://\S+"#, with: "[URL]", options: .regularExpression)
        return boundedText(value, bytes: 1000)
    }
    private func activeAppChanged() {
        guard isRunning else { return }
        // Immediately invalidate a result from the previous foreground surface.
        lastJudgmentFingerprint = ""; lastJudgmentSurface = nil
        classificationTask?.cancel(); classificationTask = nil; revision = UUID()
        activeRequestID = nil; needsCapture = true
        lastRequestedAt = .distantPast
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            // Inspecting Onward preserves the last color and pauses distraction timing.
            holdStatusWhileInspecting(); detachAX(); return
        }
        status = .observing; judgment = nil
        attachAX(); lastCaptureAt = .distantPast; capture()
    }
    private func holdStatusWhileInspecting() {
        let timestamp = Date()
        policy.acceptUncertainty(at: timestamp)
        status = policy.isHoldingStatus ? policy.status(at: timestamp) : .observing
    }
    private func attachAX() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return }
        if observedPID == app.processIdentifier { return }
        detachAX(); observedPID = app.processIdentifier
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, event, pointer in
            guard let pointer else { return }
            let model = Unmanaged<ObserverModel>.fromOpaque(pointer).takeUnretainedValue()
            let changedWindow = event as String == kAXFocusedWindowChangedNotification
            var sourcePID: pid_t = 0
            guard AXUIElementGetPid(element, &sourcePID) == .success else { return }
            let originPID = sourcePID
            Task { @MainActor in
                // Events queued before detaching an app must not clear the new app's status.
                guard model.isRunning, model.observedPID == originPID,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == originPID else { return }
                model.lastJudgmentFingerprint = ""
                if changedWindow { model.lastJudgmentSurface = nil; model.status = .observing }
                model.needsCapture = true; model.activeRequestID = nil
                model.classificationTask?.cancel(); model.classificationTask = nil
                guard Date().timeIntervalSince(model.lastCaptureAt) > 1 else { return }
                model.capture()
            }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &observer) == .success, let observer else { return }
        axObserver = observer
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        for event in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification, kAXTitleChangedNotification, kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            AXObserverAddNotification(observer, appElement, event as CFString, pointer)
            if let window = AXRead.element(appElement, kAXFocusedWindowAttribute) { AXObserverAddNotification(observer, window, event as CFString, pointer) }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    private func detachAX() {
        if let observer = axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        axObserver = nil; observedPID = 0
    }
    func capture() {
        guard isRunning, !sleeping, captureTask == nil, let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier, app.bundleIdentifier != "com.apple.loginwindow",
              SystemActivity.idleSeconds < 300 else { return }
        let pid = app.processIdentifier; let name = app.localizedName ?? "Unknown app"; let bundle = app.bundleIdentifier ?? ""
        let ocr = ocrEnabled; let browserText = browserTextEnabled; let generation = revision
        lastCaptureAt = Date()
        captureTask = Task { [weak self] in
            do {
                let captured = try await CaptureEngine.capture(pid: pid, name: name, bundleID: bundle, ocr: ocr, pageText: browserText)
                guard let self else { return }
                self.captureTask = nil
                guard self.isRunning, self.revision == generation, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                if let judgedSurface = self.lastJudgmentSurface, judgedSurface != FocusSurface(captured) {
                    self.lastJudgmentSurface = nil; self.lastJudgmentFingerprint = ""
                }
                self.observation = captured
                self.needsCapture = false
                if !captured.hasEvidence {
                    // Freeze before updating status so unreadable captures cannot escalate or alert.
                    self.judgment = nil; self.lastJudgmentFingerprint = captured.fingerprint
                    self.lastJudgmentSurface = FocusSurface(captured)
                    self.policy.acceptUncertainty(at: Date())
                }
                self.attachAX()
                self.updateStatus()
                self.classifyIfNeeded()
            } catch {
                guard let self else { return }
                self.captureTask = nil
                guard self.isRunning, self.revision == generation else { return }
                self.revision = UUID(); self.classificationTask?.cancel(); self.classificationTask = nil
                self.activeRequestID = nil; self.needsCapture = true
                self.lastJudgmentFingerprint = ""; self.lastJudgmentSurface = nil; self.judgment = nil; self.status = .observing
                self.lastCaptureAt = .distantPast
            }
        }
    }
    private func classifyIfNeeded() {
        guard isRunning, !sleeping, !needsCapture, captureTask == nil, classificationTask == nil, Date() >= retryAfter,
              let snapshot = observation, NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
              snapshot.bundleID != Bundle.main.bundleIdentifier,
              snapshot.bundleID != "com.apple.loginwindow", status != .idle,
              Date().timeIntervalSince(snapshot.capturedAt) < 12 else { return }
        guard hasKey else { error = JevError.missingKey.localizedDescription; status = .unavailable; return }
        guard snapshot.hasEvidence else { return }
        let fingerprint = snapshot.fingerprint
        let changed = lastJudgmentFingerprint != fingerprint
        guard Date().timeIntervalSince(lastRequestedAt) >= (changed ? 3 : 20) else { return }
        let generation = revision; let goal = self.goal; let context = self.context; let key = apiKey
        let recent = entries.prefix(5).reversed().map { $0.observation.summary }
        lastRequestedAt = Date()
        let requestID = UUID(); activeRequestID = requestID
        classificationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.activeRequestID == requestID { self.classificationTask = nil; self.activeRequestID = nil } }
            do {
                let payload = try JevContract.request(goal: goal, context: context, observation: snapshot, recent: recent, corrections: self.correctionNotes)
                self.lastRequestData = payload
                let result = try await self.client.classify(payload: payload, key: key)
                self.requestCount += 1; self.inputTokens += result.inputTokens
                guard !Task.isCancelled, self.activeRequestID == requestID, self.isRunning, self.revision == generation,
                      self.observation?.fingerprint == fingerprint,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { return }
                self.judgment = result; self.lastJudgmentFingerprint = fingerprint; self.lastJudgmentSurface = FocusSurface(snapshot)
                self.policy.accept(result, at: Date()); self.error = nil
                let entry = ActivityEntry(goal: goal, observation: snapshot, judgment: result)
                if self.entries.first?.observation.fingerprint != fingerprint || self.entries.first?.judgment?.alignment != result.alignment { self.record(entry) }
                self.updateStatus()
            } catch {
                guard !Task.isCancelled, self.revision == generation else { return }
                self.error = error.localizedDescription; self.status = .unavailable; self.policy.reset()
                self.retryAfter = Date().addingTimeInterval(20)
            }
        }
    }
    private func updateStatus() {
        guard isRunning else { return }
        guard error == nil else { status = .unavailable; return }
        guard let current = observation,
              lastJudgmentSurface?.canDisplayJudgment(for: current, foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, at: Date()) == true else { status = .observing; return }
        let previous = status; status = policy.status(at: Date())
        // Retaining a color does not establish new evidence for a reminder.
        guard !policy.isHoldingStatus else { return }
        if status == .focused || status == .unclear { redAlerted = false }
        if status == .drifting && previous != .drifting && Date().timeIntervalSince(lastAlertAt) > 90 {
            alert(title: "You're drifting", body: "\(current.appName) appears unrelated to: \(goal)", sound: false)
            lastAlertAt = Date()
        }
        if status == .distracted && !redAlerted {
            redAlerted = true
            alert(title: "Come back to your goal", body: goal, sound: soundEnabled)
        }
    }
    func correct(_ alignment: Alignment) {
        guard let observation else { return }
        let note = "For goal \(goal), the user marked this specific activity as \(alignment.rawValue): \(observation.summary)"
        correctionNotes.append(boundedText(note, bytes: 1000)); correctionNotes = Array(correctionNotes.suffix(6))
        record(ActivityEntry(goal: goal, observation: observation, judgment: judgment, correction: alignment))
        resetEvidence(); classifyIfNeeded()
    }
    private func record(_ entry: ActivityEntry) {
        entries.insert(entry, at: 0); entries = Array(entries.prefix(150))
        if saveHistory { do { try AppStorage.append(entry) } catch { self.error = "Could not save local history: \(error.localizedDescription)" } }
    }
    func saveKey(_ key: String) {
        do { try Credentials.save(key); apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines); hasKey = !apiKey.isEmpty; error = nil; resetEvidence() }
        catch { self.error = "Could not save API key: \(error.localizedDescription)" }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacy("Privacy_Accessibility")
    }
    func requestScreenRecording() { CGRequestScreenCaptureAccess(); openPrivacy("Privacy_ScreenCapture") }
    func openPrivacy(_ pane: String) { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) } }
    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.notificationFailure = message.map { "Could not request notifications: \($0)" }
                if !granted && message == nil { self.notificationAuthorizationStatus = .denied }
                self.updateNotificationError()
                self.refreshNotifications()
            }
        }
    }
    func refreshNotifications() {
        lastNotificationSettingsRead = Date()
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let authorizationStatus = settings.authorizationStatus
            Task { @MainActor in
                guard let self else { return }
                self.notificationAuthorizationStatus = authorizationStatus
                self.notificationsGranted = authorizationStatus == .authorized
                self.updateNotificationError()
            }
        }
    }
    private func updateNotificationError() {
        var messages = notificationFailure.map { [$0] } ?? []
        if notificationAuthorizationStatus == .denied { messages.append(Self.notificationsDisabledMessage) }
        notificationError = messages.isEmpty ? nil : messages.joined(separator: " ")
    }
    func alert(title: String, body: String, sound: Bool) {
        // Play exactly one warning, even when macOS banner permission is denied.
        if sound { playWarningSound(restart: false) }
        guard notificationsGranted else {
            notificationFailure = notificationAuthorizationStatus == .denied ? nil : "Enable notifications in Onward Settings to show reminder banners."
            updateNotificationError()
            publishBrowserStatus(); return
        }
        let content = UNMutableNotificationContent(); content.title = title; content.body = boundedText(body, bytes: 500)
        // The local player owns audio; a notification sound would create a second chime.
        content.sound = nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.notificationFailure = message.map { "Could not deliver reminder: \($0)" }
                self.updateNotificationError()
                self.publishBrowserStatus()
            }
        }
    }
    func previewWarningSound() { playWarningSound(restart: true) }
    private func playWarningSound(restart: Bool) {
        do {
            try SoundPlayer.shared.playWarning(warningSound, volume: warningVolume, restart: restart)
            soundError = nil
        } catch { soundError = error.localizedDescription }
    }
    func previewTimeCue() { playTimeCue(preview: true) }
    private func playTimeCue(preview: Bool) {
        do {
            try SoundPlayer.shared.playTimeCue(timeCueSound, volume: timeCueVolume, preview: preview)
            soundError = nil
        } catch { soundError = error.localizedDescription }
    }
    private func configureTimeCues() {
        timeCueController?.setSuspended(sleeping || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow")
        timeCueController?.configure(enabled: timeCueEnabled, interval: timeCueInterval)
        if !timeCueEnabled { SoundPlayer.shared.stopTimeCue() }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; launchAtLogin = enabled }
        catch { self.error = "Login item: \(error.localizedDescription)" }
    }
    func exportLatest() {
        guard let data = lastRequestData else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "onward-last-jev-request.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url) }
        catch { self.error = error.localizedDescription }
    }
    var displayStatus: FocusStatus { presentation.status(for: status) }
    var screenGlowVisible: Bool {
        showScreenGlow && isRunning && !goal.isEmpty && !sleeping && status != .idle &&
        NSWorkspace.shared.frontmostApplication.map { $0.bundleIdentifier != "com.apple.loginwindow" } == true
    }
    var isHoldingStatus: Bool {
        presentation.establishedStatus != nil && (policy.isHoldingStatus || ![.focused, .drifting, .distracted].contains(status))
    }
    var offGoalSeconds: Int { presentation.offGoalSeconds }
    var sessionDuration: String {
        let seconds = Int(now.timeIntervalSince(startedAt ?? now)); return String(format: "%02d:%02d", max(0, seconds / 60), max(0, seconds % 60))
    }
}
