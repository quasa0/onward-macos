import SwiftUI
import OnwardCore

extension Notification.Name {
    static let onwardNavigate = Notification.Name("Onward.Navigate")
}

private let libraryAccent = Color(red: 0.17, green: 0.43, blue: 0.33)

struct SavedGoalSwitcher: View {
    @ObservedObject var model: ObserverModel
    var manage: () -> Void

    var body: some View {
        Menu {
            ForEach(model.goalLibrary.goals) { goal in
                Button { model.selectGoal(goal.id) } label: {
                    if goal.id == model.goalLibrary.activeGoalID {
                        Label(goal.title, systemImage: "checkmark")
                    } else { Text(goal.title) }
                }
            }
            if !model.goalLibrary.goals.isEmpty { Divider() }
            Button("Manage goals…", systemImage: "flag", action: manage)
        } label: {
            Text(model.activeSavedGoal?.title ?? "Saved goals").lineLimit(1)
        }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 200, alignment: .trailing)
            .font(.system(size: 12, weight: .medium))
            .accessibilityLabel("Switch saved goal")
            .accessibilityValue(model.activeSavedGoal?.title ?? "No saved goal selected")
    }
}

private struct GoalEditorDraft: Identifiable {
    var id = UUID()
    var savedGoal: SavedGoal?
}

struct GoalsView: View {
    @ObservedObject var model: ObserverModel
    @State private var editor: GoalEditorDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Goals").font(.system(size: 28, weight: .semibold))
                    Text("Keep each project's direction, context and examples together.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                Button("New goal", systemImage: "plus") { editor = GoalEditorDraft() }
                    .buttonStyle(.borderedProminent)
            }
            if let error = model.knowledgeError { InlineNotice(message: error) }
            if model.goalLibrary.goals.isEmpty {
                ContentUnavailableView {
                    Label("A place for each goal", systemImage: "flag")
                } description: {
                    Text("Save Reelful, Fastclip or your next project. Switch goals without losing what Onward learns about each one.")
                } actions: {
                    Button("Create a goal") { editor = GoalEditorDraft() }.buttonStyle(.borderedProminent)
                }.padding(.vertical, 36)
            } else {
                VStack(spacing: 12) {
                    ForEach(model.goalLibrary.goals) { goal in goalRow(goal) }
                }
                Text("Switching goals keeps your observer running or paused. Examples stay attached to the goal they were saved for.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.sheet(item: $editor) { draft in GoalEditor(model: model, savedGoal: draft.savedGoal) }
    }

    private func goalRow(_ goal: SavedGoal) -> some View {
        let active = goal.id == model.goalLibrary.activeGoalID
        let examples = model.goalLibrary.annotations.filter { $0.goalID == goal.id }.count
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(goal.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                    if active {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(libraryAccent)
                    }
                    Spacer()
                    Button("Edit") { editor = GoalEditorDraft(savedGoal: goal) }
                    if !active {
                        Button("Switch to goal") { model.selectGoal(goal.id) }.buttonStyle(.bordered)
                    }
                }
                Text(goal.goal).font(.system(size: 13)).lineSpacing(2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !goal.context.isEmpty {
                    Text(goal.context).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                }
                Label("\(examples) learned \(examples == 1 ? "example" : "examples")", systemImage: "checklist")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(active ? libraryAccent.opacity(0.42) : .clear, lineWidth: 1))
    }
}

private struct GoalEditor: View {
    @ObservedObject var model: ObserverModel
    let savedGoal: SavedGoal?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var instructions: String
    @State private var context: String
    @FocusState private var titleFocused: Bool

    init(model: ObserverModel, savedGoal: SavedGoal?) {
        self.model = model; self.savedGoal = savedGoal
        _title = State(initialValue: savedGoal?.title ?? "")
        _instructions = State(initialValue: savedGoal?.goal ?? "")
        _context = State(initialValue: savedGoal?.context ?? "")
    }

    private var isActive: Bool { savedGoal?.id == model.goalLibrary.activeGoalID && savedGoal != nil }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(savedGoal == nil ? "New goal" : "Edit goal").font(.system(size: 24, weight: .semibold))
                Text(isActive ? "Changes apply to your active goal when you save." : "Save this goal and make it your active direction.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").fontWeight(.medium)
                TextField("Reelful, Fastclip, Writing…", text: $title).textFieldStyle(.roundedBorder)
                    .focused($titleFocused).accessibilityLabel("Goal name")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("What are you working toward?").fontWeight(.medium)
                TextField("Describe what counts as progress for this goal", text: $instructions, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3...7).accessibilityLabel("Goal instructions")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Context (optional)").fontWeight(.medium)
                TextField("Useful tools, related research, boundaries and exceptions…", text: $context, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3...6).accessibilityLabel("Saved goal context")
                Text("Add broad guidance here. Teach individual activities in Review.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let error = model.knowledgeError { InlineNotice(message: error) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isActive ? "Save changes" : savedGoal == nil ? "Create & switch" : "Save & switch") {
                    model.saveGoal(id: savedGoal?.id, title: title, goal: instructions, context: context)
                    if model.knowledgeError == nil { dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }.font(.system(size: 13)).padding(28).frame(width: 560)
            .onAppear { titleFocused = true }
    }
}

struct ReviewView: View {
    @ObservedObject var model: ObserverModel
    @State private var section: String
    @State private var query = ""
    @State private var savedMessage: String?

    init(model: ObserverModel, initialSection: String = "To review") {
        self.model = model
        _section = State(initialValue: initialSection)
    }

    private var pending: [ActivityEntry] {
        model.reviewEntries.filter { matches($0.observation, note: "") }.sorted {
            let leftUnclear = $0.judgment?.alignment == .unclear || $0.judgment == nil
            let rightUnclear = $1.judgment?.alignment == .unclear || $1.judgment == nil
            return leftUnclear != rightUnclear ? leftUnclear : $0.date > $1.date
        }
    }
    private var annotations: [GoalAnnotation] {
        model.goalAnnotations.filter { matches($0.observation, note: $0.note) }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Review").font(.system(size: 28, weight: .semibold))
                Text("Teach Onward what is relevant. Your examples guide future judgments for this goal.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let activeGoal = model.activeSavedGoal {
                HStack(spacing: 12) {
                    Image(systemName: "flag.fill").foregroundStyle(libraryAccent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reviewing for").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(activeGoal.title).font(.system(size: 15, weight: .semibold))
                    }
                    Spacer()
                    SavedGoalSwitcher(model: model) {
                        NotificationCenter.default.post(name: .onwardNavigate, object: "Goals")
                    }
                }.padding(16).background(libraryAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                if let error = model.knowledgeError { InlineNotice(message: error) }
                reviewControls
                if let savedMessage {
                    HStack {
                        Label(savedMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(libraryAccent).accessibilityLabel(savedMessage)
                        Spacer()
                        if section == "To review" {
                            Button("View learned examples") { section = "Learned examples" }.buttonStyle(.link)
                        }
                    }.font(.system(size: 12))
                }
                if section == "To review" { pendingList(goal: activeGoal) }
                else { annotationList(goal: activeGoal) }
            } else {
                ContentUnavailableView {
                    Label("Choose a goal first", systemImage: "flag")
                } description: {
                    Text("Examples need a goal. Save one so Onward knows what you want to make progress on.")
                } actions: {
                    Button("Open goals") { NotificationCenter.default.post(name: .onwardNavigate, object: "Goals") }
                        .buttonStyle(.borderedProminent)
                }.padding(.vertical, 36)
            }
        }.onChange(of: model.goalLibrary.activeGoalID) { _, _ in savedMessage = nil; query = "" }
    }

    private var reviewControls: some View {
        VStack(spacing: 14) {
            Picker("Review section", selection: $section) {
                Text("To review (\(model.pendingReviewCount))").tag("To review")
                Text("Learned examples (\(model.goalAnnotations.count))").tag("Learned examples")
            }.pickerStyle(.segmented)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find an app, page, thread or note", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("Search review activities")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear review search")
                }
            }.font(.system(size: 13)).padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.1), lineWidth: 1))
        }
    }

    @ViewBuilder private func pendingList(goal: SavedGoal) -> some View {
        if pending.isEmpty {
            ContentUnavailableView(query.isEmpty ? "Nothing waiting for review" : "No matching activities",
                systemImage: query.isEmpty ? "checkmark.circle" : "magnifyingglass",
                description: Text(query.isEmpty ? "New activities appear here as you work on \(goal.title). Learned examples stay in the next tab." : "Try another app, page or thread name."))
                .padding(.vertical, 24)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Uncertain judgments appear first. A note is optional.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                LazyVStack(spacing: 14) {
                    ForEach(pending) { entry in
                        ActivityReviewCard(entry: entry, goalTitle: goal.title) { alignment, note in
                            model.annotate(entry, alignment: alignment, note: note)
                            if model.knowledgeError == nil { savedMessage = "Example saved for \(goal.title)." }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func annotationList(goal: SavedGoal) -> some View {
        if annotations.isEmpty {
            ContentUnavailableView(query.isEmpty ? "No learned examples yet" : "No matching examples",
                systemImage: query.isEmpty ? "checklist" : "magnifyingglass",
                description: Text(query.isEmpty ? "Mark an activity Relevant or Irrelevant. Onward remembers your answer for \(goal.title)." : "Try another app, page, thread or note."))
                .padding(.vertical, 24)
        } else {
            LazyVStack(spacing: 14) {
                ForEach(annotations) { annotation in
                    LearnedExampleCard(model: model, annotation: annotation, goalTitle: goal.title)
                }
            }
        }
    }

    private func matches(_ observation: Observation, note: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || [observation.summary, observation.activeWorkspace?.project ?? "", observation.activeWorkspace?.thread ?? "", note]
            .joined(separator: " ").localizedCaseInsensitiveContains(term)
    }
}

private struct ActivityReviewCard: View {
    let entry: ActivityEntry
    let goalTitle: String
    let annotate: (OnwardCore.Alignment, String) -> Void
    @State private var note = ""
    private var unsure: Bool { entry.judgment == nil || entry.judgment?.alignment == .unclear }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                CapturedActivitySummary(observation: entry.observation, date: entry.date)
                HStack(spacing: 7) {
                    Image(systemName: unsure ? "questionmark.circle.fill" : "sparkle")
                    Text(unsure ? "Jev is unsure — your answer helps" : "Jev: \(entry.judgment?.alignment.label ?? "Observed")")
                        .fontWeight(unsure ? .medium : .regular)
                    if let judgment = entry.judgment, !unsure {
                        Spacer()
                        Text("\(Int(judgment.probability * 100))%").monospacedDigit()
                    }
                }.font(.system(size: 12)).foregroundStyle(unsure ? Color.primary : .secondary)
                TextField("Optional note: why does this belong, or not?", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    .accessibilityLabel("Optional explanation for \(entry.observation.appName)")
                HStack(spacing: 10) {
                    Text("For \(goalTitle)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 12)
                    Button("Relevant", systemImage: "checkmark") { annotate(.onGoal, note) }.buttonStyle(.bordered)
                    Button("Irrelevant", systemImage: "xmark") { annotate(.offGoal, note) }.buttonStyle(.bordered)
                }
                CapturedTextDisclosure(observation: entry.observation)
            }
        }.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(unsure ? Color.orange.opacity(0.4) : .clear, lineWidth: 1))
    }
}

private struct LearnedExampleCard: View {
    @ObservedObject var model: ObserverModel
    let annotation: GoalAnnotation
    let goalTitle: String
    @State private var editing = false
    @State private var note = ""
    @State private var alignment: OnwardCore.Alignment = .onGoal

    private var relevant: Bool { annotation.alignment == .onGoal || annotation.alignment == .supporting }
    private var label: String {
        annotation.alignment == .unclear ? "Needs review for \(goalTitle)" : "\(relevant ? "Relevant" : "Irrelevant") to \(goalTitle)"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CapturedActivitySummary(observation: annotation.observation, date: annotation.createdAt)
                HStack {
                    Label(label, systemImage: annotation.alignment == .unclear ? "questionmark.circle" : relevant ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(relevant ? libraryAccent : .primary)
                    Spacer()
                    if !editing {
                        Button("Edit") { note = annotation.note; alignment = relevant ? .onGoal : .offGoal; editing = true }
                    }
                }
                if editing {
                    Picker("Relevance", selection: $alignment) {
                        Text("Relevant").tag(OnwardCore.Alignment.onGoal)
                        Text("Irrelevant").tag(OnwardCore.Alignment.offGoal)
                    }.pickerStyle(.segmented)
                    TextField("Why this belongs, or not (optional)", text: $note, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...5).accessibilityLabel("Example note")
                    HStack {
                        Button("Remove example", role: .destructive) { model.removeAnnotation(annotation.id) }
                        Spacer()
                        Button("Cancel") { editing = false }
                        Button("Save changes") {
                            model.updateAnnotation(annotation.id, alignment: alignment, note: note)
                            if model.knowledgeError == nil { editing = false }
                        }.buttonStyle(.borderedProminent)
                    }
                } else if !annotation.note.isEmpty {
                    Text(annotation.note).font(.system(size: 13)).lineSpacing(2).textSelection(.enabled)
                }
                CapturedTextDisclosure(observation: annotation.observation)
            }
        }
    }
}

private struct CapturedActivitySummary: View {
    let observation: Observation
    let date: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            appIcon(observation.bundleID).frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(observation.appName).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 12)
                    Text(date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                if let workspace = observation.activeWorkspace {
                    Text([workspace.project, workspace.thread].filter { !$0.isEmpty }.joined(separator: " / "))
                        .font(.system(size: 14, weight: .medium)).lineLimit(3)
                } else {
                    Text(observation.tabTitle.isEmpty ? observation.windowTitle : observation.tabTitle)
                        .font(.system(size: 14, weight: .medium)).lineLimit(3)
                }
                if !observation.url.isEmpty {
                    Text(observation.url).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                }
            }.textSelection(.enabled)
        }
    }
}

private struct CapturedTextDisclosure: View {
    let observation: Observation

    var body: some View {
        DisclosureGroup("Captured context") {
            ScrollView {
                Text(evidence).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.frame(height: 180).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .padding(.top, 7)
        }.font(.system(size: 12)).foregroundStyle(.secondary)
    }

    private var evidence: String {
        let sections = [
            ("Focused element", observation.focusedElement), ("Selected text", observation.selectedText),
            ("App text", observation.accessibilityText), ("Browser text", observation.browserText), ("Local OCR", observation.ocrText)
        ].filter { !$0.1.isEmpty }.map { "\($0.0)\n\($0.1)" }
        return sections.isEmpty ? "No additional text was captured for this activity." : sections.joined(separator: "\n\n")
    }
}

struct JevSpendView: View {
    @ObservedObject var model: ObserverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Jev spend").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Estimated · USD").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 36) {
                spendColumn(title: "Today", totals: model.todaySpend)
                spendColumn(title: "Since tracking began", totals: model.totalSpend)
            }
            Text("Tracking started \(model.spendLedger.trackingStartedAt.formatted(date: .abbreviated, time: .shortened)). This is Onward's local estimate, not your account bill.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if model.totalSpend.unreportedRequests > 0 || model.totalSpend.unpricedRequests > 0 {
                InlineNotice(message: "\(model.totalSpend.unreportedRequests.formatted()) requests have no reported usage; \(model.totalSpend.unpricedRequests.formatted()) have no known price. Their cost is not included.")
            }
            DisclosureGroup("How the estimate works") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Jev 1.13.0: $0.042 per million input tokens. Output tokens are free. Estimates use returned usage, including responses that arrive after you switch activities. Canceled requests or missing usage may add cost that Onward cannot measure.")
                        .fixedSize(horizontal: false, vertical: true)
                    Link("TypeSafe model pricing", destination: URL(string: "https://docs.typesafe.ai/models")!)
                }.font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2).padding(.top, 8)
            }.font(.system(size: 12))
            if let error = model.spendError { InlineNotice(message: error) }
        }
    }

    private func spendColumn(title: String, totals: JevSpendTotals) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(JevSpendFormat.usd(nanodollars: totals.estimatedNanodollars))
                .font(.system(size: 25, weight: .medium)).monospacedDigit().tracking(-0.4)
            Text("\(totals.requestCount.formatted()) \(totals.requestCount == 1 ? "request" : "requests") · \(totals.inputTokens.formatted()) input tokens")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CameraAttentionSettingsView: View {
    @ObservedObject var model: ObserverModel

    private var snapshot: CameraAttentionSnapshot { model.cameraSnapshot }
    private var stale: Bool {
        model.cameraEnabled && model.isRunning &&
        [.present, .lookingAway, .absent, .uncertain].contains(snapshot.status) && !snapshot.isFresh(at: model.now)
    }
    private var statusTitle: String {
        if model.cameraPermissionPending { return "Waiting for camera permission" }
        if stale { return "Waiting for a camera reading" }
        switch snapshot.status {
        case .disabled: return model.cameraEnabled ? "Camera paused" : "Camera off"
        case .permissionNeeded: return "Camera permission needed"
        case .calibrating: return "Calibrating — look at the center of your screen"
        case .present: return snapshot.calibrated ? "Facing the screen" : "Face detected"
        case .lookingAway: return snapshot.isDistracted ? "Looking away" : "Looking away · within grace period"
        case .absent: return snapshot.isDistracted ? "No face detected" : "No face detected · within grace period"
        case .uncertain: return "Camera is unsure"
        case .unavailable: return "Camera unavailable"
        }
    }
    private var statusSymbol: String {
        if stale || model.cameraPermissionPending { return "ellipsis.circle" }
        switch snapshot.status {
        case .disabled: return "camera"
        case .permissionNeeded: return "lock"
        case .calibrating: return "viewfinder"
        case .present: return "checkmark.circle"
        case .lookingAway: return "eye.slash"
        case .absent: return "person.crop.circle.badge.questionmark"
        case .uncertain: return "questionmark.circle"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Camera attention").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 24) {
                Text("Notice when I look away from the screen")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Toggle("Camera attention", isOn: Binding(get: { model.cameraEnabled }, set: model.setCameraEnabled))
                    .labelsHidden().fixedSize().disabled(model.cameraPermissionPending)
            }
            Text("Uses Apple Vision on this Mac to estimate face presence and screen attention. No photos or video are saved or sent to Jev.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if model.cameraEnabled || snapshot.status == .permissionNeeded || model.cameraPermissionPending {
                VStack(alignment: .leading, spacing: 8) {
                    Label(statusTitle, systemImage: statusSymbol).font(.system(size: 13, weight: .medium))
                    if stale {
                        Text("A fresh camera reading is needed before attention can be estimated.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if !snapshot.reason.isEmpty && !model.cameraPermissionPending {
                        Text(snapshot.reason).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                if snapshot.status == .permissionNeeded {
                    Button("Open camera settings", systemImage: "gearshape") { model.openPrivacy("Privacy_Camera") }
                }
                if model.cameraEnabled {
                    HStack(spacing: 12) {
                        Button(snapshot.calibrated ? "Recalibrate" : "Calibrate for this screen", systemImage: "viewfinder", action: model.calibrateCamera)
                            .disabled(snapshot.status == .calibrating || model.cameraPermissionPending)
                        Text(snapshot.calibrated ? "Calibrate again if your screen or position changes." : "Look at the center of your screen and hold still.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Allows 8 seconds of looking away or 12 seconds without a face before treating it as distraction. Pauses with your focus session, except during calibration.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Attention is approximate. The camera cannot tell what you are looking at or whether you are using a phone.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 13))
    }
}
