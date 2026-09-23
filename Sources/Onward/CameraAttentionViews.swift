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
            case .present:
                title = "Facing the screen"; symbol = "checkmark.circle.fill"; color = cameraGreen; needsAttention = false
            case .uncertain where !snapshot.baselineReady:
                title = "Learning your screen direction"; symbol = "scope"; color = cameraYellow; needsAttention = true
            case .lookingAway:
                title = snapshot.isDistracted ? "Looking away" : "Looking away · grace period"
                symbol = "arrow.turn.up.right"; color = cameraYellow; needsAttention = true
            case .absent:
                title = snapshot.isDistracted ? "Nobody in view" : "Nobody in view · grace period"
                symbol = "person.crop.circle.badge.questionmark"; color = cameraYellow; needsAttention = true
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
                            HeadDirectionView(snapshot: model.cameraSnapshot, now: model.now)
                            Button("I'm facing my screen", systemImage: "scope", action: model.useCurrentCameraDirection)
                                .disabled(model.cameraPermissionPending)
                            Text("Optional. Onward learns your usual direction by itself. Use this if your screen is far from the camera.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(width: 200, alignment: .leading)
                    }
                    Text(model.cameraSnapshot.reason.isEmpty ? "Waiting for your camera." : model.cameraSnapshot.reason)
                        .font(.system(size: 13)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                Text("Green means your head faces your usual screen direction. Yellow means a large turn away, nobody in view, or an uncertain reading. Eyes are not tracked. Your goal's color is separate.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ContentUnavailableView {
                    Label(model.cameraPermissionPending ? "Waiting for camera permission" : "Camera attention is off", systemImage: "camera")
                } description: {
                    Text("Enable it to see your live view and estimate whether you face your screen. Camera frames stay on this Mac and are never recorded.")
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

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            CameraFeedView(frame: model.cameraFrame, snapshot: model.cameraSnapshot, now: model.now,
                           enabled: model.cameraEnabled).frame(width: 148)
            VStack(alignment: .leading, spacing: 8) {
                Text("Camera attention").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                CameraStatusLabel(snapshot: model.cameraSnapshot, now: model.now, enabled: model.cameraEnabled)
                Button("Open live view", action: open).buttonStyle(.link).font(.system(size: 12))
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
            .accessibilityLabel(enabled ? "Mirrored live camera view with detected face and body markers" : "Camera off")
    }

    @ViewBuilder private func landmarks(in size: CGSize) -> some View {
        let state = CameraVisualState(snapshot: snapshot, at: now, enabled: enabled)
        if let bounds = snapshot.faceBounds, bounds.minX.isFinite, bounds.minY.isFinite,
           bounds.width > 0, bounds.height > 0 {
            RoundedRectangle(cornerRadius: 10).strokeBorder(state.color.opacity(0.9), lineWidth: 2)
                .frame(width: bounds.width * size.width, height: bounds.height * size.height)
                .position(x: (1 - bounds.midX) * size.width, y: (1 - bounds.midY) * size.height)
        }
        ForEach(Array(snapshot.bodyPoints.enumerated()), id: \.offset) { _, point in
            if point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) {
                Circle().fill(.white).frame(width: 5, height: 5)
                    .overlay(Circle().strokeBorder(.black.opacity(0.65), lineWidth: 1))
                    .position(x: (1 - point.x) * size.width, y: (1 - point.y) * size.height)
            }
        }
    }
}

/// Shows how far the head is turned and tilted from the usual screen direction. Magnitudes only:
/// the left/right sign of Vision's yaw is not verified, so no direction is claimed.
struct HeadDirectionView: View {
    let snapshot: CameraAttentionSnapshot
    let now: Date

    private var offset: CGPoint? {
        guard snapshot.isFresh(at: now), let point = snapshot.headOffset, point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Head direction").font(.system(size: 12, weight: .medium))
            meter("Turn", value: offset.map { abs($0.x) })
            meter("Tilt", value: offset.map { abs($0.y) })
            Text(offset == nil ? (snapshot.baselineReady ? "No clear reading" : "Learning your usual direction")
                 : "Past the line for 8 seconds counts as looking away")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("Head direction")
            .accessibilityValue(offset.map { "Turn \(Int(abs($0.x) * 100)) percent, tilt \(Int(abs($0.y) * 100)) percent of the looking-away limit" } ?? "No reading")
    }

    /// 0 = usual direction, the marked line = looking-away limit, the bar end = 1.5× the limit.
    private func meter(_ title: String, value: Double?) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.07))
                    if let value {
                        Capsule().fill(value >= 1 ? cameraYellow : cameraGreen)
                            .frame(width: max(6, width * min(1, value / 1.5)))
                    }
                    Rectangle().fill(.primary.opacity(0.45)).frame(width: 1.5, height: 12).offset(x: width / 1.5 - 0.75)
                }
            }.frame(height: 8)
        }
    }
}
