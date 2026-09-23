import SwiftUI
import AppKit
import OnwardCore
import UserNotifications

extension FocusStatus {
    var color: Color {
        switch self {
        case .focused: return Color(red: 0.07, green: 0.49, blue: 0.29)
        case .drifting: return Color(red: 0.98, green: 0.75, blue: 0.14)
        case .distracted: return Color(red: 0.79, green: 0.19, blue: 0.19)
        default: return Color(red: 0.49, green: 0.54, blue: 0.57)
        }
    }
    var symbol: String {
        switch self {
        case .focused: return "arrow.up.right"
        case .drifting: return "arrow.turn.up.left"
        case .distracted: return "exclamationmark"
        case .paused, .idle: return "pause"
        case .unclear: return "questionmark"
        case .observing: return "ellipsis"
        case .unavailable: return "exclamationmark.triangle"
        default: return "scope"
        }
    }
}

private let muted = Color.secondary
private let accent = Color(red: 0.17, green: 0.43, blue: 0.33)

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.09), lineWidth: 1))
    }
}

struct InlineNotice: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Dashboard: View {
    @ObservedObject var model: ObserverModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: String
    @State private var goalDraft = ""
    @State private var contextDraft = ""
    @State private var inspect = false
    @State private var correctionMessage: String?
    @State private var reviewSection = "To review"
    @State private var cameraCalibration = false

    init(model: ObserverModel, initialSelection: String = "Now", initialReviewSection: String = "To review") {
        self.model = model
        _selection = State(initialValue: initialSelection)
        _reviewSection = State(initialValue: initialReviewSection)
        _goalDraft = State(initialValue: model.goal)
        _contextDraft = State(initialValue: model.context)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.primary.opacity(0.08)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if selection == "Now" { nowView }
                    else if selection == "Goals" { GoalsView(model: model) }
                    else if selection == "Review" { ReviewView(model: model, initialSection: reviewSection) }
                    else if selection == "Activity" { activityView }
                    else if selection == "Camera" { CameraAttentionView(model: model, calibrate: { cameraCalibration = true }) }
                    else { SettingsView(model: model) }
                }.padding(32).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.frame(minWidth: 860, minHeight: 690)
            .tint(accent)
            .onAppear { goalDraft = model.goal; contextDraft = model.context }
            .onChange(of: model.goal) { _, value in goalDraft = value; correctionMessage = nil }
            .onChange(of: model.context) { _, value in contextDraft = value }
            .onChange(of: model.observation?.id) { _, _ in correctionMessage = nil }
            .onChange(of: model.goalLibrary.activeGoalID) { _, _ in correctionMessage = nil }
            .onReceive(NotificationCenter.default.publisher(for: .onwardNavigate)) { notification in
                if let destination = notification.object as? String {
                    if destination == "Review" { openReview() }
                    else if destination == "Camera calibration" { selection = "Camera"; cameraCalibration = true }
                    else { selection = destination }
                }
            }
            .sheet(isPresented: $inspect) { EvidenceView(model: model) }
            .sheet(isPresented: $cameraCalibration) { CameraCalibrationView(model: model) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right").font(.system(size: 18, weight: .semibold)).foregroundStyle(accent)
                Text("Onward").font(.system(size: 21, weight: .semibold))
            }.padding(.horizontal, 20).padding(.top, 28)
            List(selection: Binding<String?>(get: { selection }, set: { if let value = $0 { selection = value } })) {
                Label("Now", systemImage: "scope").tag("Now")
                Label("Goals", systemImage: "flag").tag("Goals")
                HStack {
                    Label("Review", systemImage: "checklist")
                    Spacer()
                    if model.pendingReviewCount > 0 {
                        Text(model.pendingReviewCount.formatted()).font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }.tag("Review")
                Label("Activity", systemImage: "clock.arrow.circlepath").tag("Activity")
                Label("Camera", systemImage: "camera").tag("Camera")
                Label("Settings", systemImage: "slider.horizontal.3").tag("Settings")
            }.listStyle(.sidebar).scrollContentBackground(.hidden).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 6) {
                Label(model.isRunning ? "Observer on" : "Observer paused", systemImage: model.isRunning ? "record.circle" : "pause.circle")
                    .font(.system(size: 12, weight: .medium))
                Text(model.isRunning ? "Session \(model.sessionDuration)" : "Ready when you are")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(muted)
                Divider().padding(.vertical, 7)
                Text("Jev today · estimated").font(.system(size: 11)).foregroundStyle(muted)
                Text("\(JevSpendFormat.usd(nanodollars: model.todaySpend.estimatedNanodollars)) USD")
                    .font(.system(size: 14, weight: .medium)).monospacedDigit()
            }.padding(20)
        }.frame(width: 185).background(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.965))
    }

    private var nowView: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Right now").font(.system(size: 13, weight: .medium)).foregroundStyle(muted)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: model.displayStatus.symbol).font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(statusInk).accessibilityHidden(true)
                    Text(model.displayStatus.title).font(.system(size: 32, weight: .semibold)).tracking(-0.6)
                }
                Text(statusDetail).font(.system(size: 13)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }.padding(.top, 4)
            if model.cameraEnabled {
                CameraPreviewCard(model: model, open: { selection = "Camera" }, calibrate: { cameraCalibration = true })
            }
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("Your goal").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            SavedGoalSwitcher(model: model) { selection = "Goals" }
                        }
                        TextField("What do you want to make progress on?", text: $goalDraft, axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 21, weight: .medium)).lineLimit(2...4)
                            .accessibilityLabel("Your goal")
                            .onSubmit { startFocus() }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Context (optional)").font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                        TextField("Related tasks, useful research, allowed detours…", text: $contextDraft, axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...3)
                            .accessibilityLabel("Goal context, optional")
                    }
                    HStack(spacing: 10) {
                        Text("Specific goals are easier to recognize.").font(.system(size: 12)).foregroundStyle(muted)
                        Spacer(minLength: 8)
                        if model.isRunning {
                            Button("Pause", systemImage: "pause", action: model.togglePause).buttonStyle(.bordered)
                        }
                        Button(model.isRunning ? "Update goal" : "Start focus", systemImage: "arrow.up.right", action: startFocus)
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if !model.accessibilityGranted || !model.screenGranted || !model.hasKey {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Finish setup").font(.system(size: 15, weight: .semibold))
                    Text("Connect Jev and let Onward read your current app.").font(.system(size: 13)).foregroundStyle(muted)
                    HStack(spacing: 10) {
                        permissionButton("App text", granted: model.accessibilityGranted, action: model.requestAccessibility)
                        permissionButton("Local OCR", granted: model.screenGranted, action: model.requestScreenRecording)
                        permissionButton("Jev", granted: model.hasKey) { selection = "Settings" }
                    }
                }
            }
            if let error = model.error { InlineNotice(message: error) }
            if let error = model.knowledgeError { InlineNotice(message: error) }
            if model.pendingReviewCount > 0 {
                Button { openReview() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checklist").font(.system(size: 17)).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Teach Onward what belongs").font(.system(size: 13, weight: .semibold))
                            Text("\(model.pendingReviewCount) \(model.pendingReviewCount == 1 ? "activity" : "activities") to review for this goal")
                                .font(.system(size: 12)).foregroundStyle(muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
                    }.padding(14).contentShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
                    .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            observationView
        }
    }

    private var statusInk: Color {
        // Yellow remains vivid in the HUD; darker text is needed on a light dashboard.
        model.displayStatus == .drifting ? Color.primary : model.displayStatus.color
    }

    private func startFocus() { model.start(goal: goalDraft, context: contextDraft) }

    private var observationView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Current activity").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Inspect text", systemImage: "text.magnifyingglass") { inspect = true }
                    .disabled(model.observation == nil)
            }
            if let observation = model.observation {
                HStack(alignment: .top, spacing: 12) {
                    appIcon(observation.bundleID).frame(width: 36, height: 36).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(observation.appName).font(.system(size: 13, weight: .semibold))
                        Text(observation.tabTitle.isEmpty ? observation.windowTitle : observation.tabTitle)
                            .font(.system(size: 13)).lineLimit(2).textSelection(.enabled)
                        if !observation.url.isEmpty {
                            Text(observation.url).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(muted).lineLimit(2).textSelection(.enabled)
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(observation.sources.joined(separator: " · ")).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Text("\(observation.textCount.formatted()) characters").monospacedDigit().fixedSize()
                }.font(.system(size: 12)).foregroundStyle(muted)
                if let judgment = model.judgment {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: judgment.alignment == .onGoal ? "checkmark.circle" : judgment.alignment == .offGoal ? "arrow.turn.up.left" : "questionmark.circle")
                                .accessibilityHidden(true)
                            Text(judgment.alignment.label).fontWeight(.medium)
                            Spacer()
                            Text("\(Int(judgment.probability * 100))% probability").foregroundStyle(muted).monospacedDigit()
                        }.font(.system(size: 13))
                        HStack(spacing: 10) {
                            Text("Teach this goal").font(.system(size: 12)).foregroundStyle(muted)
                            Spacer()
                            Button("Relevant", systemImage: "checkmark") { correctCurrentActivity(.onGoal) }
                            Button("Irrelevant", systemImage: "xmark") { correctCurrentActivity(.offGoal) }
                        }.controlSize(.small)
                        Button("Review examples and add notes") { openReview() }
                            .buttonStyle(.link).font(.system(size: 12))
                    }.padding(.top, 2)
                }
                if let correctionMessage {
                    Label(correctionMessage, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(accent)
                    Button("Edit this example in Review") { openReview(learned: true) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            } else {
                Text("Start a focus session, then use your Mac. Your current app and captured text will appear here.")
                    .font(.system(size: 13)).foregroundStyle(muted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
            }
        }
    }

    private func correctCurrentActivity(_ alignment: OnwardCore.Alignment) {
        model.correct(alignment)
        if model.knowledgeError == nil {
            correctionMessage = "Saved as \(alignment == .onGoal ? "relevant" : "irrelevant") for \(model.activeSavedGoal?.title ?? "this goal")."
        }
    }

    private func openReview(learned: Bool = false) {
        reviewSection = learned ? "Learned examples" : "To review"
        selection = "Review"
    }

    private var statusDetail: String {
        if let reason = model.cameraDistractionReason { return reason }
        if model.isHoldingStatus && model.isRunning && ![.idle, .unavailable].contains(model.status) {
            return "Keeping your last status while waiting for a clear judgment. The distraction timer is paused."
        }
        switch model.status {
        case .ready: return "Set a goal. Onward will notice when your attention moves away."
        case .focused: return "Your current activity supports what you set out to do."
        case .drifting: return "This looks unrelated. \(model.offGoalSeconds)s away from your goal."
        case .distracted: return "Your attention has been elsewhere for \(model.offGoalSeconds)s. Take one step back toward your goal."
        case .observing: return "Waiting for a fresh view of your work and Jev's judgment."
        case .unclear: return "The evidence is uncertain. Add context if this activity belongs to your goal."
        case .paused: return "Resume when you're ready. Capture and classification are paused."
        case .idle: return "Observation resumes when you return."
        case .unavailable: return model.error ?? "Check the capture permissions and Jev connection."
        }
    }

    private var activityView: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Activity").font(.system(size: 28, weight: .semibold))
                HStack {
                    Text("\(model.entries.count) recent observations").foregroundStyle(muted)
                    Spacer()
                    Button("Open local history", systemImage: "folder") { NSWorkspace.shared.open(AppStorage.directory) }
                }.font(.system(size: 12))
            }
            if model.entries.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock", description: Text("Your observations appear here after your first focus session."))
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.entries) { entry in
                        activityRow(entry)
                        Divider()
                    }
                }
            }
        }
    }

    private func activityRow(_ entry: ActivityEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            appIcon(entry.observation.bundleID).frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.observation.appName).fontWeight(.semibold)
                    Spacer(minLength: 16)
                    Text(entry.date, style: .time).font(.system(size: 12)).monospacedDigit().foregroundStyle(muted)
                }.font(.system(size: 13))
                Text(entry.observation.tabTitle.isEmpty ? entry.observation.windowTitle : entry.observation.tabTitle)
                    .font(.system(size: 13)).lineLimit(2)
                if !entry.observation.url.isEmpty {
                    Text(entry.observation.url).font(.system(size: 12, design: .monospaced)).foregroundStyle(muted).lineLimit(1)
                }
                Text(entry.correction.map { "You marked: \($0.label)" } ?? entry.judgment?.alignment.label ?? "Observed")
                    .font(.system(size: 12, weight: .medium))
                Text("Goal: \(entry.goal)").font(.system(size: 12)).foregroundStyle(muted).lineLimit(2)
            }.textSelection(.enabled)
        }.padding(.vertical, 18)
    }

    private func permissionButton(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: granted ? "checkmark.circle" : "plus.circle")
        }.buttonStyle(.bordered).font(.system(size: 12))
            .accessibilityLabel("\(title), \(granted ? "enabled" : "requires setup")")
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 24) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).labelsHidden().fixedSize()
        }
    }
}

private struct SoundVolumeControl: View {
    let title: String
    @Binding var volume: Double
    let preview: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 112, alignment: .leading)
            Slider(value: $volume, in: 0...1, onEditingChanged: { editing in
                if !editing { preview() }
            })
            .accessibilityLabel(title)
            .accessibilityValue("\(Int((volume * 100).rounded())) percent")
            Text("\(Int((volume * 100).rounded()))%")
                .monospacedDigit().foregroundStyle(muted).frame(width: 38, alignment: .trailing)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: ObserverModel
    @State private var key = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Settings").font(.system(size: 28, weight: .semibold))
            SettingsSection(title: "Jev connection") {
                Label(model.hasKey ? "API key saved in macOS Keychain" : "Add a TypeSafe API key to classify your activity", systemImage: model.hasKey ? "checkmark.circle" : "key")
                    .foregroundStyle(muted)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.hasKey ? "Replace API key" : "API key").fontWeight(.medium)
                    HStack(spacing: 10) {
                        SecureField("TypeSafe API key", text: $key).textFieldStyle(.roundedBorder)
                            .accessibilityLabel(model.hasKey ? "Replacement TypeSafe API key" : "TypeSafe API key")
                            .onSubmit(saveKey)
                        Button("Save key", action: saveKey).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Text("\(model.requestCount) judgments · \(model.inputTokens.formatted()) input tokens this session")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(muted)
            }
            Divider()
            JevSpendView(model: model)
            Divider()
            SettingsSection(title: "Capture") {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsToggle(title: "Local OCR with Apple Vision", isOn: $model.ocrEnabled)
                    Text("Window images stay on this Mac. Only extracted text is sent to Jev.")
                        .font(.system(size: 12)).foregroundStyle(muted)
                }
                SettingsToggle(title: "Read browser page text", isOn: $model.browserTextEnabled)
                SettingsToggle(title: "Save text observations locally", isOn: $model.saveHistory)
                VStack(alignment: .leading, spacing: 6) {
                    SettingsToggle(title: "Save window screenshots for Review", isOn: $model.saveScreenshots)
                    Text("Keeps an image of the focused window for each saved observation and learned example, so Review shows what you were looking at. Stored only on this Mac; Jev never receives images.")
                        .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    if let error = model.screenshotError { InlineNotice(message: error) }
                }
                HStack(spacing: 10) {
                    Button(model.accessibilityGranted ? "App text enabled" : "Enable app text", action: model.requestAccessibility)
                    Button(model.screenGranted ? "OCR permission enabled" : "Enable local OCR", action: model.requestScreenRecording)
                }
                Text("Helium, Chrome and Safari share the exact tab URL through Automation. For more page text, allow JavaScript from Apple Events in the browser or use the optional extension.")
                    .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                Button("Show browser extension", systemImage: "puzzlepiece.extension") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension") { NSWorkspace.shared.open(url) }
                }
            }
            Divider()
            CameraAttentionSettingsView(model: model)
            Divider()
            SettingsSection(title: "Reminders") {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsToggle(title: "Show Onward below the notch", isOn: $model.showHUD)
                    Text("The status circle moves out of the way when your pointer approaches.").font(.system(size: 12)).foregroundStyle(muted)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsToggle(title: "Show screen-edge glow", isOn: $model.showScreenGlow)
                    Text("A slight moving yellow glow when you drift. Red pulses with warnings. Returning to your goal gives a five-second aqua-green healing effect that starts broad and shrinks, with rising plus signs and sparkles. It stops if you leave green.")
                        .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsToggle(title: "Play a sound while distracted", isOn: $model.soundEnabled)
                    Text("At the start of red, then every 3–7 seconds at random.")
                        .font(.system(size: 12)).foregroundStyle(muted)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("Warning sound")
                        Spacer()
                        Picker("Warning sound", selection: Binding(get: { model.warningSound }, set: {
                            model.warningSound = $0; model.previewWarningSound()
                        })) {
                            ForEach(WarningSoundChoice.allCases) { choice in Text(choice.title).tag(choice) }
                        }.labelsHidden().pickerStyle(.menu).frame(width: 180)
                            .accessibilityLabel("Warning sound")
                            .help("Choose a sound to hear a preview.")
                        Button("Preview", systemImage: "speaker.wave.2", action: model.previewWarningSound)
                            .accessibilityLabel("Preview warning sound")
                    }
                    Text(model.warningSound.detail).font(.system(size: 12)).foregroundStyle(muted)
                }
                SoundVolumeControl(title: "Warning volume", volume: $model.warningVolume, preview: model.previewWarningSound)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Turn red after confirmed distraction")
                        Spacer()
                        Text("\(Int(model.redAfter)) seconds").monospacedDigit().foregroundStyle(muted)
                    }
                    Slider(value: $model.redAfter, in: 15...180, step: 15)
                        .accessibilityLabel("Seconds away from goal before turning red")
                        .accessibilityValue("\(Int(model.redAfter)) seconds")
                    Text("Checking and uncertain readings pause this timer.").font(.system(size: 12)).foregroundStyle(muted)
                }
                HStack(spacing: 10) {
                    Button(notificationButtonTitle, action: configureNotifications)
                    Button("Test reminder") {
                        model.alert(title: "Onward is listening", body: model.goal.isEmpty ? "Set a goal when you're ready." : model.goal, sound: model.soundEnabled)
                    }.disabled(!model.notificationsGranted)
                }
                if let error = model.notificationError { InlineNotice(message: error) }
            }
            Divider()
            SettingsSection(title: "Time cues") {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsToggle(title: "Play a quiet time cue", isOn: $model.timeCueEnabled)
                    Text("Keeps time even when focus is paused. Pauses while your Mac is locked or asleep.")
                        .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Every")
                    Spacer()
                    Picker("Time cue interval", selection: $model.timeCueInterval) {
                        ForEach(TimeCueInterval.allCases) { interval in
                            Text(interval.rawValue == 60 ? "1 minute" : "\(interval.rawValue) seconds").tag(interval)
                        }
                    }.labelsHidden().pickerStyle(.menu).frame(width: 180)
                        .accessibilityLabel("Time cue interval")
                }
                Text(timeCueTiming).font(.system(size: 12)).monospacedDigit().foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("Cue sound")
                    Spacer()
                    Picker("Time cue sound", selection: Binding(get: { model.timeCueSound }, set: {
                        model.timeCueSound = $0; model.previewTimeCue()
                    })) {
                        ForEach(TimeCueSoundChoice.allCases) { choice in Text(choice.title).tag(choice) }
                    }.labelsHidden().pickerStyle(.menu).frame(width: 180)
                        .accessibilityLabel("Time cue sound")
                        .help("Choose a sound to hear a preview.")
                    Button("Preview", systemImage: "speaker.wave.2", action: model.previewTimeCue)
                        .accessibilityLabel("Preview time cue")
                }
                SoundVolumeControl(title: "Cue volume", volume: $model.timeCueVolume, preview: model.previewTimeCue)
                if let error = model.soundError { InlineNotice(message: error) }
            }
            Divider()
            SettingsSection(title: "Startup") {
                SettingsToggle(title: "Open Onward at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                Text("Onward opens paused. Start a session when you have a goal.").font(.system(size: 12)).foregroundStyle(muted)
            }
            if let error = model.error { InlineNotice(message: error) }
        }.toggleStyle(.switch).font(.system(size: 13))
    }
    private var timeCueTiming: String {
        let seconds = stride(from: 0, to: 60, by: model.timeCueInterval.rawValue).map { String(format: ":%02d", $0) }.joined(separator: ", ")
        if model.timeCueEnabled {
            let next = TimeCueSchedule.nextBoundary(after: model.now, interval: model.timeCueInterval)
            return "Aligned to the clock · next at \(next.formatted(date: .omitted, time: .standard))"
        }
        return "Aligned to each minute: \(seconds)."
    }
    private func saveKey() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.saveKey(key)
        if model.error == nil { key = "" }
    }
    private var notificationButtonTitle: String {
        if model.notificationAuthorizationStatus == .denied { return "Open notification settings" }
        return model.notificationsGranted ? "Notifications enabled" : "Enable notifications"
    }
    private func configureNotifications() {
        if model.notificationAuthorizationStatus == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") { NSWorkspace.shared.open(url) }
        } else { model.requestNotifications() }
    }
}

struct EvidenceView: View {
    @ObservedObject var model: ObserverModel
    @Environment(\.dismiss) var dismiss
    @State private var source = "All text"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Captured text").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("Export last Jev request", action: model.exportLatest).disabled(model.lastRequestData == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Inspect the latest capture. Export saves the exact last request sent to Jev, which may precede this capture.")
                .font(.system(size: 13)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            Picker("Source", selection: $source) {
                ForEach(["All text", "Accessibility", "Browser", "Local OCR", "Warnings"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            ScrollView {
                Text(evidence).font(.system(size: 12, design: .monospaced)).lineSpacing(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.1), lineWidth: 1))
        }.padding(24).frame(width: 780, height: 580)
    }
    private var evidence: String {
        guard let o = model.observation else { return "No observation yet." }
        switch source {
        case "Accessibility": return o.accessibilityText.isEmpty ? "No app text captured." : o.accessibilityText
        case "Browser": return o.url.isEmpty && o.browserText.isEmpty ? "No browser text captured." : [o.tabTitle, o.url, o.browserText].joined(separator: "\n\n")
        case "Local OCR":
            if o.ocrText.isEmpty, o.activeWorkspace?.source == "macOS Accessibility" {
                return "Native app text identified the active conversation. Local OCR was not needed for this capture."
            }
            return o.ocrText.isEmpty ? "No text recognized. Check Screen Recording permission." : o.ocrText
        case "Warnings": return o.warnings.isEmpty ? "No capture warnings." : o.warnings.joined(separator: "\n\n")
        default: return "APP: \(o.appName) [\(o.bundleID)]\nWINDOW: \(o.windowTitle)\nTAB: \(o.tabTitle)\nURL: \(o.url)\nFOCUSED: \(o.focusedElement)\nSELECTED: \(o.selectedText)\n\nACCESSIBILITY\n\(o.accessibilityText)\n\nBROWSER\n\(o.browserText)\n\nLOCAL OCR\n\(o.ocrText)"
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: ObserverModel
    @State private var goalDraft = ""
    var open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: model.displayStatus.symbol)
                    .foregroundStyle(model.displayStatus == .drifting ? Color.primary : model.displayStatus.color).accessibilityHidden(true)
                Text(model.displayStatus.title).fontWeight(.semibold)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Your goal").font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                    Spacer()
                    SavedGoalSwitcher(model: model) { navigate("Goals") }
                }
                TextField("Set one goal to get started", text: $goalDraft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .medium)).lineLimit(1...4)
                    .accessibilityLabel("Your goal")
                    .onSubmit { model.start(goal: goalDraft, context: model.context) }
            }
            if let observation = model.observation {
                Text(observation.summary).font(.system(size: 12)).foregroundStyle(muted).lineLimit(2)
            }
            if model.pendingReviewCount > 0 {
                Button("Review activity (\(model.pendingReviewCount))", systemImage: "checklist") { navigate("Review") }
                    .font(.system(size: 12))
            }
            HStack {
                Text("Jev today · estimated").foregroundStyle(muted)
                Spacer()
                Text("\(JevSpendFormat.usd(nanodollars: model.todaySpend.estimatedNanodollars)) USD").monospacedDigit()
            }.font(.system(size: 11))
            Divider()
            HStack {
                Button("Open Onward", action: open)
                Spacer()
                if goalDraft.trimmingCharacters(in: .whitespacesAndNewlines) != model.goal {
                    Button("Set goal") { model.start(goal: goalDraft, context: model.context) }
                        .disabled(goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button(model.isRunning ? "Pause" : "Resume", action: model.togglePause).disabled(model.goal.isEmpty)
                }
            }
            Button("Quit Onward") { NSApp.terminate(nil) }.font(.system(size: 12)).buttonStyle(.borderless).foregroundStyle(muted)
        }.padding(20).frame(width: 320)
            .onAppear { goalDraft = model.goal }
            .onChange(of: model.goal) { _, value in goalDraft = value }
    }
    private func navigate(_ destination: String) {
        open()
        NotificationCenter.default.post(name: .onwardNavigate, object: destination)
    }
}

struct GoalHUD: View {
    static let side: CGFloat = 44
    static let canvasWidth: CGFloat = 252
    static let canvasHeight: CGFloat = 60
    @ObservedObject var model: ObserverModel
    private var hasJudgment: Bool { [.focused, .drifting, .distracted].contains(model.displayStatus) }
    private var foreground: Color { model.displayStatus == .drifting ? Color(red: 0.19, green: 0.13, blue: 0.02) : (hasJudgment ? .white : .primary) }
    var body: some View {
        ZStack {
            HUDGlow(status: model.displayStatus)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 40, height: 40)
                .background {
                    if hasJudgment { Circle().fill(model.displayStatus.color) }
                    else { Circle().fill(.ultraThinMaterial) }
                }
                .overlay(Circle().strokeBorder(foreground.opacity(hasJudgment ? 0.2 : 0.08), lineWidth: 1))
                .frame(width: Self.side, height: Self.side)
        }.frame(width: Self.canvasWidth, height: Self.canvasHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Onward. \(model.displayStatus.title). Goal: \(model.goal)")
            .accessibilityValue(model.isHoldingStatus ? "Showing the last established status" : "")
    }
}

func appIcon(_ bundle: String) -> some View {
    Group {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable() }
        else { Image(systemName: "app").resizable().foregroundStyle(.secondary) }
    }
}
