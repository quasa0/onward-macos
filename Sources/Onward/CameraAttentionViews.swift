import SwiftUI
import CoreGraphics
import OnwardCore

private let cameraGreen = Color(nsColor: .systemGreen)
private let cameraYellow = Color(red: 0.98, green: 0.75, blue: 0.14)

private struct CameraVisualState {
    let title: String
    let symbol: String
    let color: Color
    let needsAttention: Bool

    init(snapshot: CameraAttentionSnapshot, at now: Date, enabled: Bool) {
        if !enabled {
            title = "Camera off"; symbol = "camera"; color = .secondary; needsAttention = false
        } else if !snapshot.isFresh(at: now) && ![.disabled, .permissionNeeded, .unavailable].contains(snapshot.status) {
            title = "Waiting for a reading"; symbol = "questionmark.circle"; color = cameraYellow; needsAttention = true
        } else {
            switch snapshot.status {
            case .present where snapshot.calibrated:
                title = "Facing the screen"; symbol = "checkmark.circle.fill"; color = cameraGreen; needsAttention = false
            case .present:
                title = "Face visible · calibrate gaze"; symbol = "viewfinder"; color = cameraYellow; needsAttention = true
            case .lookingAway:
                title = snapshot.isDistracted ? "Looking away" : "Looking away · grace period"
                symbol = "eye.slash"; color = cameraYellow; needsAttention = true
            case .absent:
                title = snapshot.isDistracted ? "No face detected" : "No face · grace period"
                symbol = "person.crop.circle.badge.questionmark"; color = cameraYellow; needsAttention = true
            case .calibrating:
                title = "Calibrating"; symbol = "viewfinder"; color = cameraYellow; needsAttention = true
            case .permissionNeeded:
                title = "Camera access needed"; symbol = "lock"; color = cameraYellow; needsAttention = true
            case .unavailable:
                title = "Camera unavailable"; symbol = "exclamationmark.triangle"; color = cameraYellow; needsAttention = true
            case .uncertain:
                title = "Attention is uncertain"; symbol = "questionmark.circle"; color = cameraYellow; needsAttention = true
            case .disabled:
                title = "Camera paused"; symbol = "pause.circle"; color = .secondary; needsAttention = false
            }
        }
    }
}

struct CameraAttentionView: View {
    @ObservedObject var model: ObserverModel
    var calibrate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Camera").font(.system(size: 28, weight: .semibold))
                    Text("See what Onward can observe about your attention.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                Toggle("Camera attention", isOn: Binding(get: { model.cameraEnabled }, set: model.setCameraEnabled))
                    .toggleStyle(.switch).fixedSize().disabled(model.cameraPermissionPending)
            }
            if model.cameraEnabled {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        CameraStatusLabel(snapshot: model.cameraSnapshot, now: model.now, enabled: true)
                        Spacer()
                        Text("Camera attention").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 22) {
                        CameraFeedView(frame: model.cameraFrame, snapshot: model.cameraSnapshot, now: model.now,
                                       enabled: model.cameraEnabled, showsLiveLabel: true)
                        VStack(alignment: .leading, spacing: 12) {
                            GazeDirectionView(snapshot: model.cameraSnapshot, now: model.now)
                            Button(model.cameraSnapshot.calibrated ? "Recalibrate" : "Calibrate for this screen", systemImage: "viewfinder", action: calibrate)
                                .buttonStyle(.borderedProminent).disabled(model.cameraPermissionPending)
                            Text("Use the calibration dot to teach Onward your usual screen position.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(width: 180, alignment: .leading)
                    }
                    Text(model.cameraSnapshot.reason.isEmpty ? "Waiting for your camera." : model.cameraSnapshot.reason)
                        .font(.system(size: 13)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                Text("Green means you appear to face the screen. Yellow means you look away, are out of view, or the reading is uncertain. Your goal's color is separate.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ContentUnavailableView {
                    Label(model.cameraPermissionPending ? "Waiting for camera permission" : "Camera attention is off", systemImage: "camera")
                } description: {
                    Text("Enable it to see your live view and calibrate approximate screen attention. Camera frames stay on this Mac and are never recorded.")
                } actions: {
                    if model.cameraSnapshot.status == .permissionNeeded {
                        Button("Open camera settings") { model.openPrivacy("Privacy_Camera") }
                    } else {
                        Button("Enable camera") { model.setCameraEnabled(true) }
                            .buttonStyle(.borderedProminent).disabled(model.cameraPermissionPending)
                    }
                }.padding(.vertical, 35)
            }
            Text("Local Apple Vision · No recording · Camera images never go to Jev")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct CameraPreviewCard: View {
    @ObservedObject var model: ObserverModel
    var open: () -> Void
    var calibrate: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            CameraFeedView(frame: model.cameraFrame, snapshot: model.cameraSnapshot, now: model.now,
                           enabled: model.cameraEnabled).frame(width: 148)
            VStack(alignment: .leading, spacing: 8) {
                Text("Camera attention").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                CameraStatusLabel(snapshot: model.cameraSnapshot, now: model.now, enabled: model.cameraEnabled)
                HStack(spacing: 12) {
                    Button("Open live view", action: open).buttonStyle(.link)
                    if !model.cameraSnapshot.calibrated {
                        Button("Calibrate", action: calibrate).buttonStyle(.link)
                    }
                }.font(.system(size: 12))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }
}

struct CameraStatusLabel: View {
    let snapshot: CameraAttentionSnapshot
    let now: Date
    let enabled: Bool

    var body: some View {
        let state = CameraVisualState(snapshot: snapshot, at: now, enabled: enabled)
        HStack(spacing: 8) {
            Circle().fill(state.color).frame(width: 9, height: 9).accessibilityHidden(true)
            Label(state.title, systemImage: state.symbol).font(.system(size: 13, weight: .medium))
        }.accessibilityElement(children: .combine)
    }
}

/// The frame and landmarks use the same mirrored image plane; gaze direction is already user-relative.
struct CameraFeedView: View {
    let frame: CGImage?
    let snapshot: CameraAttentionSnapshot
    let now: Date
    let enabled: Bool
    var showsLiveLabel = false

    private var aspectRatio: CGFloat {
        guard let frame, frame.width > 0, frame.height > 0 else { return 4 / 3 }
        return CGFloat(frame.width) / CGFloat(frame.height)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.09)
                if enabled, let frame {
                    Image(decorative: frame, scale: 1, orientation: .upMirrored).resizable().scaledToFit()
                    if snapshot.isFresh(at: now) {
                        landmarks(in: geometry.size)
                    }
                    if showsLiveLabel {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Text("Mirrored view").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(.black.opacity(0.55), in: Capsule())
                            }
                        }.padding(12)
                    }
                } else {
                    VStack(spacing: 9) {
                        Image(systemName: enabled ? "camera" : "camera.fill").font(.system(size: 22))
                        Text(enabled ? "Waiting for camera" : "Camera off").font(.system(size: 11))
                    }.foregroundStyle(.white.opacity(0.65))
                }
            }
        }.aspectRatio(aspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .accessibilityLabel(enabled ? "Mirrored live camera view with detected face and eye landmarks" : "Camera off")
    }

    @ViewBuilder private func landmarks(in size: CGSize) -> some View {
        let state = CameraVisualState(snapshot: snapshot, at: now, enabled: enabled)
        if let bounds = snapshot.faceBounds, bounds.minX.isFinite, bounds.minY.isFinite,
           bounds.width > 0, bounds.height > 0 {
            RoundedRectangle(cornerRadius: 10).strokeBorder(state.color.opacity(0.9), lineWidth: 2)
                .frame(width: bounds.width * size.width, height: bounds.height * size.height)
                .position(x: (1 - bounds.midX) * size.width, y: (1 - bounds.midY) * size.height)
        }
        ForEach(Array(snapshot.pupilPoints.enumerated()), id: \.offset) { _, point in
            if point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) {
                Circle().fill(.white).frame(width: 5, height: 5)
                    .overlay(Circle().strokeBorder(.black.opacity(0.65), lineWidth: 1))
                    .position(x: (1 - point.x) * size.width, y: (1 - point.y) * size.height)
            }
        }
    }
}

struct GazeDirectionView: View {
    let snapshot: CameraAttentionSnapshot
    let now: Date

    private var offset: CGPoint? {
        guard snapshot.isFresh(at: now), snapshot.calibrated,
              let point = snapshot.gazeOffset, point.x.isFinite, point.y.isFinite else { return nil }
        return CGPoint(x: min(1, max(-1, point.x)), y: min(1, max(-1, point.y)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Approximate direction").font(.system(size: 12, weight: .medium))
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.035))
                    Path { path in
                        path.move(to: CGPoint(x: geometry.size.width / 2, y: 10))
                        path.addLine(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height - 10))
                        path.move(to: CGPoint(x: 10, y: geometry.size.height / 2))
                        path.addLine(to: CGPoint(x: geometry.size.width - 10, y: geometry.size.height / 2))
                    }.stroke(.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1).frame(width: 18, height: 18)
                    if let offset {
                        let state = CameraVisualState(snapshot: snapshot, at: now, enabled: true)
                        Circle().fill(state.color).frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                            .position(x: geometry.size.width / 2 + offset.x * (geometry.size.width / 2 - 12),
                                      y: geometry.size.height / 2 - offset.y * (geometry.size.height / 2 - 12))
                    }
                }
            }.frame(height: 90)
            Text(offset == nil ? (snapshot.calibrated ? "No reliable direction" : "Calibrate to see direction") : "Relative to your calibration")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Direction only, not a screen position.").font(.system(size: 11)).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("Approximate gaze direction")
            .accessibilityValue(directionDescription)
    }

    private var directionDescription: String {
        guard let offset else { return "No reliable direction" }
        let horizontal = abs(offset.x) < 0.2 ? "" : offset.x > 0 ? "right" : "left"
        let vertical = abs(offset.y) < 0.2 ? "" : offset.y > 0 ? "up" : "down"
        let direction = [vertical, horizontal].filter { !$0.isEmpty }.joined(separator: " and ")
        return direction.isEmpty ? "Near calibrated center" : direction
    }
}

struct CameraCalibrationView: View {
    @ObservedObject var model: ObserverModel
    var automaticallyStart = true
    @Environment(\.dismiss) private var dismiss
    @State private var sawCalibration = false
    @State private var attempted = false

    private var snapshot: CameraAttentionSnapshot { model.cameraSnapshot }
    private var success: Bool {
        snapshot.calibrationProgress >= 1 && snapshot.calibrated && (sawCalibration || !automaticallyStart)
    }
    private var failed: Bool {
        attempted && !success && (snapshot.status == .unavailable || snapshot.status == .permissionNeeded ||
                                  (sawCalibration && snapshot.status != .calibrating))
    }
    private var progress: Double { min(1, max(0, snapshot.calibrationProgress)) }
    private var title: String { success ? "Your screen position is calibrated" : failed ? "Let's try that again" : "Look at the dot and hold still" }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                ZStack {
                    Circle().strokeBorder(cameraGreen.opacity(0.13), lineWidth: 1).frame(width: 76, height: 76)
                    Circle().strokeBorder(cameraGreen.opacity(0.3), lineWidth: 2).frame(width: 40, height: 40)
                    if success {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(cameraGreen)
                    } else {
                        Circle().fill(failed ? cameraYellow : cameraGreen).frame(width: 13, height: 13)
                    }
                }.position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                Text(success ? "Done" : failed ? "Adjust your position, then retry" : "Keep your eyes here")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2 + 58)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title).font(.system(size: 23, weight: .semibold))
                            Text(success ? "You can close this and return to your work." : "Keep looking at the dot until it becomes a checkmark.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        if !success, let remaining = snapshot.calibrationSecondsRemaining {
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("\(Int(max(0, remaining).rounded(.up)))s").font(.system(size: 23, weight: .medium)).monospacedDigit()
                                Text("time left").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    HStack(alignment: .center, spacing: 18) {
                        CameraFeedView(frame: model.cameraFrame, snapshot: snapshot, now: model.now,
                                       enabled: model.cameraEnabled).frame(width: 152)
                        VStack(alignment: .leading, spacing: 9) {
                            Text(success ? "Calibration complete" : failed ? "Calibration needs another try" : "Finding a steady view")
                                .font(.system(size: 13, weight: .medium))
                            Text(snapshot.reason.isEmpty ? "Keep one face visible. Adjust your camera or lighting if needed." : snapshot.reason)
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                            ProgressView(value: success ? 1 : progress).tint(cameraGreen)
                                .accessibilityLabel("Calibration progress")
                                .accessibilityValue("\(Int(progress * 100)) percent")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.bottom, 20)
                    HStack {
                        if success {
                            Button("Calibrate again", action: beginCalibration)
                        } else {
                            Button("Cancel") { model.cancelCameraCalibration(); dismiss() }.keyboardShortcut(.cancelAction)
                        }
                        Spacer()
                        Text("Live on this Mac · Never recorded").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        if success {
                            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        } else if snapshot.status == .permissionNeeded {
                            Button("Open camera settings") { model.openPrivacy("Privacy_Camera") }.buttonStyle(.borderedProminent)
                        } else if failed {
                            Button("Try again", action: beginCalibration).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        }
                    }
                }.padding(28)
            }
        }.frame(width: 690, height: 580)
            .onAppear {
                if automaticallyStart { beginCalibration() }
                else { attempted = true; sawCalibration = snapshot.status == .calibrating }
            }
            .onChange(of: snapshot.status) { _, status in
                if status == .calibrating { sawCalibration = true }
            }
            .onDisappear { if snapshot.status == .calibrating { model.cancelCameraCalibration() } }
    }

    private func beginCalibration() {
        attempted = true; sawCalibration = false
        model.calibrateCamera()
        if snapshot.status == .calibrating { sawCalibration = true }
    }
}
