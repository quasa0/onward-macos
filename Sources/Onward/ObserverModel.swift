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
    @Published var spendLedger = JevSpendLedger()
    @Published var spendError: String?
    @Published var goalLibrary = GoalLibrary()
    @Published var knowledgeError: String?
    @Published private(set) var warningPulseID = 0
    @Published private(set) var recoveryPulseID = 0
    @Published private(set) var cameraEnabled = UserDefaults.standard.bool(forKey: "cameraAttentionEnabled")
    @Published private(set) var cameraPermissionPending = false
    @Published private(set) var cameraSnapshot = CameraAttentionSnapshot(status: .disabled)
    @Published private(set) var cameraFrame: CGImage?
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
    /// Review images of the focused window. Stored locally only; Jev receives text only.
    @Published var saveScreenshots = UserDefaults.standard.object(forKey: "saveScreenshots") as? Bool ?? true {
        didSet { UserDefaults.standard.set(saveScreenshots, forKey: "saveScreenshots"); if !saveScreenshots { latestScreenshot = nil } }
    }
    @Published private(set) var screenshotError: String?
    @Published var redAfter = UserDefaults.standard.object(forKey: "redAfter") as? Double ?? 45 { didSet { UserDefaults.standard.set(redAfter, forKey: "redAfter"); policy.redAfter = redAfter } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var apiKey = ""
    private let client = JevClient()
    private var goalStore: GoalLibraryFileStore?
    private var screenshotStore: ActivityScreenshotStore?
    private let screenshotWriter = ScreenshotWriter()
    /// The newest verified window image, bound to the text fingerprint it depicts.
    private var latestScreenshot: (fingerprint: String, jpeg: Data)?
    private var previewScreenshots: [UUID: Data] = [:]
    private var spendStore: JevSpendFileStore?
    private var lastSpendRead = Date.distantPast
    private var cameraController: CameraAttentionController?
    private var cameraPreviewVisible = false
    private var cameraPermissionTask: Task<Void, Never>?
    private var cameraOverrideActive = false
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
    private var distractionReminder = DistractionReminder()
    private var distractionReminderTimer: Timer?
    private var distractionReminderTimerID = UUID()
    private var systemSleeping = false
    private var sessionInactive = false
    private var sleeping: Bool { systemSleeping || sessionInactive }
    private var lastNotificationSettingsRead = Date.distantPast
    private var notificationFailure: String?
    private static let notificationsDisabledMessage = "Notification banners are disabled. Enable Onward in System Settings > Notifications to show reminder banners."

    init(audioEnabled: Bool = true, persistenceEnabled: Bool = true) {
        apiKey = Credentials.read() ?? ""; hasKey = !apiKey.isEmpty
        if persistenceEnabled {
            goalStore = GoalLibraryFileStore(url: AppStorage.directory.appendingPathComponent("goals.json"))
            spendStore = JevSpendFileStore(url: AppStorage.directory.appendingPathComponent("jev-spend.json"))
            screenshotStore = ActivityScreenshotStore(directory: AppStorage.directory.appendingPathComponent("screenshots", isDirectory: true))
            do {
                goalLibrary = try goalStore!.loadOrMigrate(goal: goal, context: context)
                if let active = activeSavedGoal { goal = active.goal; context = active.context }
            } catch { knowledgeError = "Saved goals could not be loaded. Existing data has been kept intact." }
            refreshSpend()
            restoreOriginalJudgments()
            cameraController = CameraAttentionController(onUpdate: { [weak self] snapshot in
                guard let self else { return }
                self.now = Date()
                self.cameraSnapshot = snapshot
                if self.isRunning && !self.sleeping &&
                    (SystemActivity.idleSeconds < 300 || self.cameraOverrideActive || self.freshCameraDistraction) {
                    self.updateStatus()
                }
            }, onFrame: { [weak self] frame in self?.cameraFrame = frame })
            configureCamera()
        } else {
            cameraEnabled = false
        }
        client.onSpendRecorded = { [weak self] ledger, error in
            guard let self else { return }
            if let ledger { self.spendLedger = ledger }
            self.spendError = error
        }
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
        if !nextGoal.isEmpty {
            var library = goalLibrary
            do {
                let existing = activeSavedGoal
                _ = try library.saveGoal(id: existing?.id, title: existing?.title ?? String(nextGoal.prefix(60)),
                                         goal: nextGoal, context: nextContext)
                guard persistGoals(library) else { return }
            } catch { knowledgeError = error.localizedDescription; return }
        }
        if nextGoal != self.goal || nextContext != self.context || nextGoal.isEmpty { presentation.reset() }
        self.goal = nextGoal
        self.context = nextContext
        if goalStore != nil {
            UserDefaults.standard.set(self.goal, forKey: "goal"); UserDefaults.standard.set(self.context, forKey: "context")
        }
        resetEvidence()
        guard !self.goal.isEmpty else { isRunning = false; status = .ready; return }
        isRunning = true; startedAt = Date(); status = .observing; error = nil
        configureCamera()
        activeAppChanged()
    }
    func togglePause() {
        if isRunning { isRunning = false; resetEvidence(); status = .paused; configureCamera() }
        else { start(goal: goal, context: context) }
    }
    func stop(publishStatus: Bool = true) {
        isRunning = false; resetEvidence(); timer?.invalidate(); timer = nil
        cameraPermissionTask?.cancel(); cameraPermissionTask = nil
        cameraController?.stop(); cameraController = nil
        cameraFrame = nil; cameraPreviewVisible = false
        timeCueController?.stop(); timeCueController = nil
        SoundPlayer.shared.stopAll()
        if publishStatus { publishBrowserStatus() }
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observers = []; detachAX()
    }
    private func resetEvidence() {
        distractionReminderTimerID = UUID()
        distractionReminderTimer?.invalidate(); distractionReminderTimer = nil
        revision = UUID(); classificationTask?.cancel(); classificationTask = nil
        activeRequestID = nil; needsCapture = true
        policy.reset(); judgment = nil; lastJudgmentFingerprint = ""; lastJudgmentSurface = nil; distractionReminder.reset()
        retryAfter = .distantPast; lastRequestedAt = .distantPast
        cameraOverrideActive = false
    }
    private func preferenceChanged(_ name: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: name); resetEvidence(); lastCaptureAt = .distantPast
    }
    private func setSleepState(systemSleeping: Bool? = nil, sessionInactive: Bool? = nil) {
        if let systemSleeping { self.systemSleeping = systemSleeping }
        if let sessionInactive { self.sessionInactive = sessionInactive }
        resetEvidence(); lastCaptureAt = .distantPast
        timeCueController?.setSuspended(sleeping)
        configureCamera()
        if sleeping { SoundPlayer.shared.stopAll() }
        if isRunning { status = sleeping ? .idle : .observing }
    }
    private func tick() {
        defer { remindIfNeeded() }
        now = Date(); accessibilityGranted = AXIsProcessTrusted(); screenGranted = CGPreflightScreenCaptureAccess()
        if now.timeIntervalSince(lastSpendRead) >= 10 { refreshSpend() }
        configureCamera()
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
        guard idle < 300 || cameraOverrideActive || freshCameraDistraction else {
            if status != .idle { resetEvidence() }
            status = .idle; return
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            if cameraOverrideActive || freshCameraDistraction { updateStatus() }
            else { holdStatusWhileInspecting() }
            return
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
                                    "savedGoalCount": goalLibrary.goals.count,
                                    "activeGoalAnnotationCount": goalAnnotations.count,
                                    "pendingReviewCount": pendingReviewCount,
                                    "jevSpend": ["estimatedNanodollars": totalSpend.estimatedNanodollars,
                                                 "todayNanodollars": todaySpend.estimatedNanodollars,
                                                 "requests": totalSpend.requestCount,
                                                 "unpricedRequests": totalSpend.unpricedRequests,
                                                 "unreportedRequests": totalSpend.unreportedRequests],
                                    "warningPulseID": warningPulseID, "recoveryPulseID": recoveryPulseID,
                                    "cameraEnabled": cameraEnabled,
                                    "cameraStatus": cameraSnapshot.status.rawValue,
                                    "cameraCalibrated": cameraSnapshot.calibrated,
                                    "cameraDistraction": cameraOverrideActive,
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
        guard isRunning, !sleeping, !cameraOverrideActive, captureTask == nil, let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier, app.bundleIdentifier != "com.apple.loginwindow",
              SystemActivity.idleSeconds < 300 else { return }
        let pid = app.processIdentifier; let name = app.localizedName ?? "Unknown app"; let bundle = app.bundleIdentifier ?? ""
        let ocr = ocrEnabled; let browserText = browserTextEnabled; let generation = revision
        let screenshot = saveScreenshots && screenshotStore != nil; let reuse = latestScreenshot?.fingerprint
        lastCaptureAt = Date()
        captureTask = Task { [weak self] in
            do {
                let result = try await CaptureEngine.capture(pid: pid, name: name, bundleID: bundle, ocr: ocr, pageText: browserText,
                                                             screenshot: screenshot, reuseScreenshotFingerprint: reuse)
                let captured = result.observation
                guard let self else { return }
                self.captureTask = nil
                guard self.isRunning, self.revision == generation, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                if let jpeg = result.screenshotJPEG, self.saveScreenshots {
                    self.latestScreenshot = (captured.fingerprint, jpeg)
                } else if self.latestScreenshot?.fingerprint != captured.fingerprint {
                    // Never let an older image stand in for different content.
                    self.latestScreenshot = nil
                }
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
        guard isRunning, !sleeping, !cameraOverrideActive, !needsCapture, captureTask == nil, classificationTask == nil, Date() >= retryAfter,
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
        // Bind the image of this exact snapshot now; a later capture may replace latestScreenshot.
        let screenshot = latestScreenshot?.fingerprint == fingerprint ? latestScreenshot?.jpeg : nil
        let recent = entries.filter(belongsToActiveGoal).prefix(5).reversed().map { $0.observation.summary }
        lastRequestedAt = Date()
        let requestID = UUID(); activeRequestID = requestID
        classificationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.activeRequestID == requestID { self.classificationTask = nil; self.activeRequestID = nil } }
            do {
                let notes = self.activeSavedGoal.map { self.goalLibrary.relevantNotes(for: $0.id, observation: snapshot) } ?? []
                let payload = try JevContract.request(goal: goal, context: context, observation: snapshot, recent: recent, corrections: notes)
                self.lastRequestData = payload
                let result = try await self.client.classify(payload: payload, key: key)
                self.requestCount += 1; self.inputTokens += result.inputTokens
                guard !Task.isCancelled, self.activeRequestID == requestID, self.isRunning, self.revision == generation,
                      self.observation?.fingerprint == fingerprint,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { return }
                self.judgment = result; self.lastJudgmentFingerprint = fingerprint; self.lastJudgmentSurface = FocusSurface(snapshot)
                if !self.cameraOverrideActive { self.policy.accept(result, at: Date()) }
                self.error = nil
                let entry = ActivityEntry(goal: goal, observation: snapshot, judgment: result, goalID: self.activeSavedGoal?.id)
                if (self.entries.first.map({ !self.belongsToActiveGoal($0) }) ?? true) ||
                    self.entries.first?.observation.fingerprint != fingerprint || self.entries.first?.judgment?.alignment != result.alignment {
                    self.record(entry, screenshot: screenshot)
                }
                self.updateStatus()
            } catch {
                guard !Task.isCancelled, self.revision == generation else { return }
                self.error = error.localizedDescription; self.status = .unavailable; self.policy.reset()
                self.retryAfter = Date().addingTimeInterval(20)
            }
        }
    }
    private func updateStatus() {
        guard isRunning, !sleeping,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else { return }
        if updateCameraDistraction() { return }
        guard error == nil else { status = .unavailable; return }
        let timestamp = Date()
        guard let current = observation,
              lastJudgmentSurface?.canDisplayJudgment(for: current, foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, at: timestamp) == true else { status = .observing; return }
        let previous = status
        let previousDisplay = displayStatus
        policy.resume(at: timestamp)
        status = policy.status(at: timestamp)
        // Recovery needs fresh evidence. Red repeats separately follow the visible color.
        guard !policy.isHoldingStatus else { return }
        if status == .focused && [.drifting, .distracted].contains(previousDisplay) { recoveryPulseID += 1 }
        if status == .drifting && previous != .drifting && Date().timeIntervalSince(lastAlertAt) > 90 {
            alert(title: "You're drifting", body: "\(current.appName) appears unrelated to: \(goal)", sound: false)
            lastAlertAt = Date()
        }
        remindIfNeeded()
    }
    private var freshCameraDistraction: Bool {
        cameraEnabled && cameraSnapshot.isFresh(at: Date()) && cameraSnapshot.isDistracted
    }
    var cameraDistractionReason: String? {
        guard cameraOverrideActive else { return nil }
        return freshCameraDistraction ? cameraSnapshot.reason : "Waiting for a clear camera reading. Keeping your last status."
    }
    /// Camera evidence can establish distraction; returning to the screen still requires
    /// a fresh app judgment before green. Missing frames never imply regained focus.
    private func updateCameraDistraction() -> Bool {
        if freshCameraDistraction {
            if !cameraOverrideActive {
                classificationTask?.cancel(); classificationTask = nil; activeRequestID = nil
                cameraOverrideActive = true
            }
            policy.acceptOffGoal(at: Date())
            status = policy.status(at: Date())
            remindIfNeeded()
            return true
        }
        guard cameraOverrideActive else { return false }
        if cameraEnabled && (cameraSnapshot.status != .present || !cameraSnapshot.isFresh(at: Date())) {
            policy.acceptUncertainty(at: Date()); status = policy.status(at: Date())
            return true
        }
        resetEvidence(); lastCaptureAt = .distantPast; status = .observing
        return true
    }
    private func remindIfNeeded() {
        let redVisible = isRunning && !sleeping && displayStatus == .distracted &&
            ![FocusStatus.paused, .idle, .ready].contains(status) &&
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow"
        let cue = distractionReminder.cue(isRedVisible: redVisible, at: ProcessInfo.processInfo.systemUptime)
        guard redVisible else {
            distractionReminderTimerID = UUID()
            distractionReminderTimer?.invalidate(); distractionReminderTimer = nil
            return
        }
        guard let cue else { return }
        distractionReminderTimer?.invalidate()
        if let next = distractionReminder.nextReminderAt {
            let timerID = UUID(); distractionReminderTimerID = timerID
            let timer = Timer(timeInterval: max(0.01, next - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.distractionReminderTimerID == timerID else { return }
                    self.distractionReminderTimer = nil; self.remindIfNeeded()
                }
            }
            timer.tolerance = 0.03
            RunLoop.main.add(timer, forMode: .common)
            distractionReminderTimer = timer
        }
        warningPulseID += 1
        if cue == .enteredRed {
            alert(title: cameraOverrideActive ? "Look back at your screen" : "Come back to your goal",
                  body: cameraDistractionReason ?? goal, sound: soundEnabled)
        } else if soundEnabled { playWarningSound(restart: false) }
    }
    func setCameraEnabled(_ enabled: Bool) {
        cameraPermissionTask?.cancel(); cameraPermissionPending = false
        guard enabled else {
            cameraEnabled = false; UserDefaults.standard.set(false, forKey: "cameraAttentionEnabled")
            configureCamera()
            if cameraOverrideActive { resetEvidence(); status = isRunning ? .observing : .paused }
            return
        }
        guard let cameraController else { return }
        cameraPermissionPending = true
        cameraPermissionTask = Task { [weak self] in
            let allowed = await cameraController.requestPermission()
            guard !Task.isCancelled, let self else { return }
            self.cameraPermissionPending = false
            self.cameraEnabled = allowed
            UserDefaults.standard.set(allowed, forKey: "cameraAttentionEnabled")
            self.configureCamera()
            if !allowed {
                self.cameraSnapshot = CameraAttentionSnapshot(status: .permissionNeeded,
                    reason: "Camera access is not allowed. Enable Onward in System Settings → Privacy & Security → Camera.")
            }
        }
    }
    func calibrateCamera() {
        guard cameraEnabled, !sleeping else { return }
        cameraController?.calibrate()
    }
    func cancelCameraCalibration() { cameraController?.cancelCalibration() }
    func setCameraPreviewVisible(_ visible: Bool) {
        guard cameraPreviewVisible != visible else { return }
        cameraPreviewVisible = visible
        if !visible { cameraFrame = nil }
        configureCamera()
    }
    /// Synthetic offscreen QA never opens a camera or writes preferences.
    func setCameraPreviewFixture(frame: CGImage?, snapshot: CameraAttentionSnapshot) {
        guard goalStore == nil, cameraController == nil else { return }
        now = Date(); cameraEnabled = true; cameraFrame = frame; cameraSnapshot = snapshot
    }
    private func configureCamera() {
        let unlocked = NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow"
        cameraController?.configure(enabled: cameraEnabled, active: isRunning && !sleeping && unlocked,
                                    suspended: sleeping || !unlocked, previewVisible: cameraPreviewVisible)
    }
    func correct(_ alignment: Alignment) {
        guard let observation else { return }
        // Only a judgment of this exact content counts as Jev's original answer.
        let currentJudgment = lastJudgmentFingerprint == observation.fingerprint ? judgment : nil
        let entry = entries.first(where: { belongsToActiveGoal($0) && $0.observation.fingerprint == observation.fingerprint })
            ?? ActivityEntry(goal: goal, observation: observation, judgment: currentJudgment, goalID: activeSavedGoal?.id)
        annotate(entry, alignment: alignment, note: "")
    }
    var activeSavedGoal: SavedGoal? { goalLibrary.goals.first { $0.id == goalLibrary.activeGoalID } }
    var goalAnnotations: [GoalAnnotation] {
        activeSavedGoal.map { goalLibrary.annotations(for: $0.id) } ?? []
    }
    var reviewEntries: [ActivityEntry] {
        guard let active = activeSavedGoal else { return [] }
        // App-only examples cannot stand for later activity with the same app name.
        let learned = Set(goalAnnotations.filter { $0.alignment != .unclear && GoalLibrary.canGuideFutureJudgments($0.observation) }
            .map { reviewIdentity($0.observation) })
        var seen = Set<String>()
        return entries.filter { entry in
            guard belongsToActiveGoal(entry), entry.correction == nil || entry.correction == .unclear else { return false }
            let identity = reviewIdentity(entry.observation)
            return !learned.contains(identity) && !goalLibrary.isReviewSkipped(goalID: active.id, identity: identity, date: entry.date)
                && seen.insert(identity).inserted
        }.sorted {
            let a = $0.judgment == nil || $0.judgment?.alignment == .unclear
            let b = $1.judgment == nil || $1.judgment?.alignment == .unclear
            return a != b ? a : $0.date > $1.date
        }
    }
    var pendingReviewCount: Int { reviewEntries.count }
    private func belongsToActiveGoal(_ entry: ActivityEntry) -> Bool {
        guard let active = activeSavedGoal else { return false }
        if let goalID = entry.goalID { return goalID == active.id }
        // TEMP-COMPAT 2026-09-22: pre-library history has no goal ID. Attribute it only
        // to the original imported goal, never a new goal with identical text. Remove
        // this nil-ID fallback when pre-library activity logs have rotated out on all
        // supported installations; retain goalID for new history and delete migration tests.
        return active.id == goalLibrary.goals.first?.id && entry.goal == active.goal
    }
    private func reviewIdentity(_ observation: Observation) -> String {
        if let workspace = observation.activeWorkspace {
            return [observation.bundleID, workspace.project, workspace.thread].joined(separator: "\u{1f}")
        }
        return [observation.bundleID, observation.url.isEmpty ? observation.windowTitle : observation.url].joined(separator: "\u{1f}")
    }
    var todaySpend: JevSpendTotals { spendLedger.today(at: now) }
    var totalSpend: JevSpendTotals { spendLedger.total }
    private func refreshSpend() {
        lastSpendRead = Date()
        guard let spendStore else { return }
        do { spendLedger = try spendStore.load(); spendError = nil }
        catch { spendError = "Jev usage could not be loaded. Existing usage data has been kept intact." }
    }
    @discardableResult private func persistGoals(_ library: GoalLibrary) -> Bool {
        do {
            try goalStore?.save(library)
            goalLibrary = library; knowledgeError = nil
            return true
        } catch { knowledgeError = "Your goal knowledge could not be saved. Existing data has been kept intact."; return false }
    }
    func saveGoal(id: UUID?, title: String, goal: String, context: String) {
        var library = goalLibrary
        do {
            _ = try library.saveGoal(id: id, title: title, goal: goal, context: context)
            guard persistGoals(library) else { return }
            applySelectedGoal()
        } catch { knowledgeError = error.localizedDescription }
    }
    func selectGoal(_ id: UUID) {
        guard goalLibrary.activeGoalID != id else { return }
        var library = goalLibrary
        do {
            try library.selectGoal(id)
            guard persistGoals(library) else { return }
            applySelectedGoal()
        } catch { knowledgeError = error.localizedDescription }
    }
    private func applySelectedGoal() {
        guard let selected = activeSavedGoal else { return }
        let resume = isRunning
        goal = selected.goal; context = selected.context
        if goalStore != nil {
            UserDefaults.standard.set(goal, forKey: "goal"); UserDefaults.standard.set(context, forKey: "context")
        }
        presentation.reset(); resetEvidence(); observation = nil; error = nil
        isRunning = resume
        status = resume ? .observing : .paused
        configureCamera()
        if resume { startedAt = Date(); activeAppChanged() }
    }
    func annotate(_ entry: ActivityEntry, alignment: Alignment, note: String) {
        guard let active = activeSavedGoal, belongsToActiveGoal(entry) else {
            knowledgeError = "Select this activity's goal before teaching Jev about it."; return
        }
        var library = goalLibrary
        do {
            if let existing = goalAnnotations.first(where: { $0.activityID == entry.id }) {
                try library.updateAnnotation(id: existing.id, alignment: alignment, note: note)
            } else {
                _ = try library.addAnnotation(goalID: active.id, alignment: alignment, note: note,
                                              observation: entry.observation, activityID: entry.id,
                                              originalJudgment: entry.judgment)
            }
            if !GoalLibrary.canGuideFutureJudgments(entry.observation) {
                // Older app-only moments are indistinguishable from this one; newer ones still return.
                try library.skipReview(goalID: active.id, identity: reviewIdentity(entry.observation), through: entry.date)
            }
            guard persistGoals(library) else { return }
            // Labeling is an explicit request to keep this example, even with history off.
            if saveScreenshots, let latestScreenshot, latestScreenshot.fingerprint == entry.observation.fingerprint,
               screenshotStore?.contains(entry.observation.id) == false {
                saveScreenshot(latestScreenshot.jpeg, for: entry.observation.id)
            }
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].correction = alignment }
            resetEvidence(); needsCapture = true
        } catch { knowledgeError = error.localizedDescription }
    }
    /// Hides this activity (and older activity with the same identity) from Review without teaching Jev.
    func skipReview(_ entry: ActivityEntry) {
        guard let active = activeSavedGoal, belongsToActiveGoal(entry) else { return }
        var library = goalLibrary
        do {
            try library.skipReview(goalID: active.id, identity: reviewIdentity(entry.observation), through: entry.date)
            persistGoals(library)
        } catch { knowledgeError = error.localizedDescription }
    }
    func updateAnnotation(_ id: UUID, alignment: Alignment, note: String) {
        var library = goalLibrary
        do {
            try library.updateAnnotation(id: id, alignment: alignment, note: note)
            guard persistGoals(library) else { return }
            resetEvidence()
        } catch { knowledgeError = error.localizedDescription }
    }
    func removeAnnotation(_ id: UUID) {
        var library = goalLibrary
        do {
            let activityID = goalAnnotations.first { $0.id == id }?.activityID
            try library.removeAnnotation(id)
            guard persistGoals(library) else { return }
            if let activityID, let index = entries.firstIndex(where: { $0.id == activityID }) { entries[index].correction = nil }
            resetEvidence()
        } catch { knowledgeError = error.localizedDescription }
    }
    private func record(_ entry: ActivityEntry, screenshot: Data? = nil) {
        entries.insert(entry, at: 0); entries = Array(entries.prefix(150))
        guard saveHistory else { return }
        do { try AppStorage.append(entry) } catch { self.error = "Could not save local history: \(error.localizedDescription)"; return }
        if saveScreenshots, let screenshot { saveScreenshot(screenshot, for: entry.observation.id) }
    }
    /// Disk failures are reported separately and never change the focus judgment.
    private func saveScreenshot(_ jpeg: Data, for observationID: UUID) {
        guard let store = screenshotStore else { return }
        let learned = Set(goalLibrary.annotations.map(\.observation.id))
        Task { [weak self, screenshotWriter] in
            do {
                try await screenshotWriter.save(jpeg, for: observationID, learned: learned, in: store)
                self?.screenshotError = nil
            } catch {
                self?.screenshotError = "Could not save a review screenshot: \(error.localizedDescription)"
            }
        }
    }
    /// Loads a saved review image without blocking the main actor.
    func screenshotData(for observationID: UUID) async -> Data? {
        if let fixture = previewScreenshots[observationID] { return fixture }
        guard let url = screenshotStore?.url(for: observationID) else { return nil }
        return await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url, options: .mappedIfSafe) }.value
    }
    /// Synthetic offscreen QA only; never used with persistent stores.
    func setReviewScreenshotFixture(_ jpeg: Data, for observationID: UUID) {
        guard goalStore == nil else { return }
        previewScreenshots[observationID] = jpeg
    }
    /// Recovers Jev's answer for older examples from their exact retained activity entry.
    private func restoreOriginalJudgments() {
        let pending = Set(goalLibrary.annotations.filter { $0.originalJudgment == nil }.compactMap(\.activityID))
        guard !pending.isEmpty else { return }
        Task { [weak self] in
            let retained = await Task.detached(priority: .utility) { AppStorage.retainedJudgments(for: pending) }.value
            guard let self, !retained.isEmpty else { return }
            var library = self.goalLibrary
            if library.restoreOriginalJudgments(retained) > 0 { self.persistGoals(library) }
        }
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
