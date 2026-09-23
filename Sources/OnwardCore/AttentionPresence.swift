import Foundation
import CoreGraphics

public enum CameraAttentionStatus: String, Codable, Sendable {
    case disabled, permissionNeeded, present, lookingAway, absent, uncertain, unavailable
}

public enum CameraAttentionReason: String, Codable, Sendable {
    case noFace, lookingAway
}

public struct CameraAttentionSnapshot: Equatable, Sendable {
    public var status: CameraAttentionStatus
    public var isDistracted: Bool
    public var reason: String
    /// True once Onward knows the user's usual screen-facing head direction.
    public var baselineReady: Bool
    public var observedAt: Date
    public var continuousSeconds: TimeInterval
    public var distractionReason: CameraAttentionReason?
    /// Vision coordinates: unmirrored, normalized, with the origin at the bottom left.
    public var faceBounds: CGRect?
    /// Visible body joints (head and shoulders) in Vision coordinates, for the live view only.
    public var bodyPoints: [CGPoint]
    /// Head turn (x, yaw) and tilt (y, pitch) relative to the usual screen direction;
    /// magnitude 1 is the looking-away limit. Not a position on the screen.
    public var headOffset: CGPoint?

    public init(status: CameraAttentionStatus, isDistracted: Bool = false, reason: String = "",
                baselineReady: Bool = false, observedAt: Date = Date(), continuousSeconds: TimeInterval = 0,
                distractionReason: CameraAttentionReason? = nil, faceBounds: CGRect? = nil,
                bodyPoints: [CGPoint] = [], headOffset: CGPoint? = nil) {
        self.status = status
        self.isDistracted = isDistracted
        self.reason = reason
        self.baselineReady = baselineReady
        self.observedAt = observedAt
        self.continuousSeconds = continuousSeconds
        self.distractionReason = distractionReason
        self.faceBounds = faceBounds
        self.bodyPoints = bodyPoints
        self.headOffset = headOffset
    }

    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age <= CameraAttentionPolicy.maximumFrameGap
    }
}

public enum CameraAttentionEvidence: Equatable, Sendable {
    case present, lookingAway, noFace, uncertain
}

/// Camera evidence is independent of the goal classifier. Unknown frames never imply attention.
public struct CameraAttentionPolicy: Sendable {
    public static let maximumFrameGap: TimeInterval = 3
    public static let lookingAwayGrace: TimeInterval = 8
    public static let absenceGrace: TimeInterval = 12
    public static let returnGrace: TimeInterval = 1

    private var candidate: CameraAttentionReason?
    private var candidateSince: Date?
    private var distracted: CameraAttentionReason?
    private var returnSince: Date?
    private var lastFrameAt: Date?
    private var latest = CameraAttentionSnapshot(status: .uncertain)

    public init() {}

    public mutating func reset() { self = Self() }

    public mutating func update(_ evidence: CameraAttentionEvidence, at now: Date,
                                baselineReady: Bool = true, uncertainReason: String? = nil) -> CameraAttentionSnapshot {
        if let lastFrameAt, now < lastFrameAt || now.timeIntervalSince(lastFrameAt) > Self.maximumFrameGap {
            reset()
        }
        lastFrameAt = now
        switch evidence {
        case .uncertain:
            candidate = nil; candidateSince = nil; distracted = nil; returnSince = nil
            latest = .init(status: .uncertain, reason: uncertainReason ?? "Camera cannot estimate attention reliably.",
                           baselineReady: baselineReady, observedAt: now)
        case .present:
            if returnSince == nil { returnSince = now }
            let elapsed = now.timeIntervalSince(returnSince!)
            if elapsed >= Self.returnGrace {
                candidate = nil; candidateSince = nil; distracted = nil
                latest = .init(status: .present, reason: "Facing your screen.",
                               baselineReady: baselineReady, observedAt: now, continuousSeconds: elapsed)
            } else if let distracted {
                latest = .init(status: distracted == .noFace ? .absent : .lookingAway, isDistracted: true,
                               reason: "Checking return to the screen.", baselineReady: baselineReady, observedAt: now,
                               continuousSeconds: elapsed, distractionReason: distracted)
            } else {
                candidate = nil; candidateSince = nil
                latest = .init(status: .uncertain, reason: "Checking screen attention.",
                               baselineReady: baselineReady, observedAt: now, continuousSeconds: elapsed)
            }
        case .lookingAway, .noFace:
            returnSince = nil
            let reason: CameraAttentionReason = evidence == .noFace ? .noFace : .lookingAway
            if candidate != reason {
                candidate = reason; candidateSince = now; distracted = nil
            }
            let elapsed = now.timeIntervalSince(candidateSince ?? now)
            let grace = reason == .noFace ? Self.absenceGrace : Self.lookingAwayGrace
            if elapsed >= grace { distracted = reason }
            latest = .init(status: reason == .noFace ? .absent : .lookingAway,
                           isDistracted: distracted != nil,
                           reason: reason == .noFace ? "No one is in view of the camera." : "Your head or body is turned well away from the screen.",
                           baselineReady: baselineReady, observedAt: now, continuousSeconds: elapsed,
                           distractionReason: reason)
        }
        return latest
    }

    public func snapshot(at now: Date) -> CameraAttentionSnapshot {
        guard let lastFrameAt, now >= lastFrameAt,
              now.timeIntervalSince(lastFrameAt) <= Self.maximumFrameGap else {
            return .init(status: .uncertain, reason: "Camera evidence is stale.",
                         baselineReady: latest.baselineReady, observedAt: lastFrameAt ?? .distantPast)
        }
        return latest
    }
}

/// Vision head pose in radians. Eyes are not used: at webcam distance they are a few pixels wide.
public struct HeadPose: Codable, Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public init(yaw: Double, pitch: Double) { self.yaw = yaw; self.pitch = pitch }
    public var isValid: Bool {
        yaw.isFinite && pitch.isFinite && abs(yaw) <= .pi / 2 && abs(pitch) <= .pi / 2
    }
}

/// Learns the user's usual screen-facing head direction without a calibration step, then
/// flags only large turns away from it. Screens beside the camera shift the learned center.
public struct HeadPoseBaseline: Codable, Equatable, Sendable {
    /// Beyond 35° left/right or 30° up/down from the usual direction counts as looking away.
    public static let awayYaw = 0.61, awayPitch = 0.52
    /// Within 24° / 20° counts as facing the screen; between the bands stays uncertain.
    public static let presentYaw = 0.42, presentPitch = 0.35
    /// Automatic learning only accepts roughly camera-facing poses.
    public static let learningLimit = 0.6
    public static let learningSamples = 6

    public private(set) var center: HeadPose?
    private var learning: [HeadPose] = []

    public init(center: HeadPose? = nil) { self.center = center?.isValid == true ? center : nil }

    public var isReady: Bool { center != nil }

    public mutating func classify(_ pose: HeadPose) -> CameraAttentionEvidence {
        guard pose.isValid else { return .uncertain }
        guard let center else {
            guard abs(pose.yaw) <= Self.learningLimit, abs(pose.pitch) <= Self.learningLimit else {
                learning.removeAll(); return .uncertain
            }
            learning.append(pose)
            if learning.count >= Self.learningSamples {
                self.center = Self.median(learning); learning.removeAll()
            }
            return .uncertain
        }
        let yaw = pose.yaw - center.yaw, pitch = pose.pitch - center.pitch
        if abs(yaw) >= Self.awayYaw || abs(pitch) >= Self.awayPitch { return .lookingAway }
        guard abs(yaw) <= Self.presentYaw, abs(pitch) <= Self.presentPitch else { return .uncertain }
        // Follow slow posture changes only from screen-facing samples, so time spent
        // looking away cannot drag the center toward the distraction.
        self.center = HeadPose(yaw: center.yaw + 0.03 * yaw, pitch: center.pitch + 0.03 * pitch)
        return .present
    }

    /// The user's explicit "I'm facing my screen" uses recent samples, not one frame.
    public mutating func setCenter(from recent: [HeadPose]) -> Bool {
        let valid = recent.filter(\.isValid)
        guard valid.count >= 2 else { return false }
        center = Self.median(valid); learning.removeAll()
        return true
    }

    public func offset(for pose: HeadPose?) -> CGPoint? {
        guard let pose, pose.isValid, let center else { return nil }
        // Signed Vision deltas; the UI shows magnitudes because the sign convention is unverified.
        return CGPoint(x: max(-1.5, min(1.5, (pose.yaw - center.yaw) / Self.awayYaw)),
                       y: max(-1.5, min(1.5, (pose.pitch - center.pitch) / Self.awayPitch)))
    }

    private static func median(_ poses: [HeadPose]) -> HeadPose {
        func middle(_ values: [Double]) -> Double {
            let sorted = values.sorted(), count = sorted.count
            return count % 2 == 1 ? sorted[count / 2] : (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }
        return HeadPose(yaw: middle(poses.map(\.yaw)), pitch: middle(poses.map(\.pitch)))
    }
}

public enum CameraBodyJoint: String, CaseIterable, Sendable {
    case nose, leftEye, rightEye, leftEar, rightEar, leftShoulder, rightShoulder, neck
}

/// What the body pose says when the face detector finds no usable face.
public enum CameraBodyCue: Equatable, Sendable {
    case none, facing, turnedAway, unclear

    /// `joints` contains only confidently visible joints, in any normalized image coordinates.
    public init(joints: [CameraBodyJoint: CGPoint]) {
        let eyes = [joints[.leftEye], joints[.rightEye]].compactMap { $0 }.count
        let nose = joints[.nose] != nil
        let anchored = [CameraBodyJoint.neck, .leftShoulder, .rightShoulder, .leftEar, .rightEar].contains { joints[$0] != nil }
        guard anchored || nose else { self = .none; return }
        if nose && eyes == 2 {
            // Facial features are visible; a nose far outside the shoulders still means a strong turn.
            if let left = joints[.leftShoulder], let right = joints[.rightShoulder], let point = joints[.nose],
               abs(left.x - right.x) > 0.02,
               abs(point.x - (left.x + right.x) / 2) / abs(left.x - right.x) > 0.5 {
                self = .turnedAway
            } else { self = .facing }
        } else if (!nose && eyes == 0 && anchored) || (nose && eyes == 1 && (joints[.leftEar] == nil) != (joints[.rightEar] == nil)) {
            // Back of the head, or a profile with one eye and one ear visible.
            self = .turnedAway
        } else { self = .unclear }
    }
}

public enum CameraAttentionEstimate {
    /// Combines one frame's face and body evidence. A single reliable face decides by head
    /// direction; the body is consulted only when no usable face is found.
    public static func evidence(faceCount: Int, pose: HeadPose?, body: CameraBodyCue,
                                baseline: inout HeadPoseBaseline) -> CameraAttentionEvidence {
        guard faceCount <= 1 else { return .uncertain }
        if faceCount == 1, let pose { return baseline.classify(pose) }
        switch body {
        case .turnedAway: return .lookingAway
        case .none: return faceCount == 0 ? .noFace : .uncertain
        case .facing, .unclear: return .uncertain
        }
    }
}
