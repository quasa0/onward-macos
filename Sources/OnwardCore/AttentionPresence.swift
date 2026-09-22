import Foundation

public enum CameraAttentionStatus: String, Codable, Sendable {
    case disabled, permissionNeeded, calibrating, present, lookingAway, absent, uncertain, unavailable
}

public enum CameraAttentionReason: String, Codable, Sendable {
    case noFace, lookingAway
}

public struct CameraAttentionSnapshot: Equatable, Sendable {
    public var status: CameraAttentionStatus
    public var isDistracted: Bool
    public var reason: String
    public var calibrated: Bool
    public var observedAt: Date
    public var continuousSeconds: TimeInterval
    public var distractionReason: CameraAttentionReason?

    public init(status: CameraAttentionStatus, isDistracted: Bool = false, reason: String = "",
                calibrated: Bool = false, observedAt: Date = Date(), continuousSeconds: TimeInterval = 0,
                distractionReason: CameraAttentionReason? = nil) {
        self.status = status
        self.isDistracted = isDistracted
        self.reason = reason
        self.calibrated = calibrated
        self.observedAt = observedAt
        self.continuousSeconds = continuousSeconds
        self.distractionReason = distractionReason
    }

    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age <= CameraAttentionPolicy.maximumFrameGap
    }
}

public enum CameraAttentionEvidence: Equatable, Sendable {
    case present, facePresent, lookingAway, noFace, uncertain
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
                                calibrated: Bool) -> CameraAttentionSnapshot {
        if let lastFrameAt, now < lastFrameAt || now.timeIntervalSince(lastFrameAt) > Self.maximumFrameGap {
            reset()
        }
        lastFrameAt = now
        switch evidence {
        case .uncertain:
            candidate = nil; candidateSince = nil; distracted = nil; returnSince = nil
            latest = .init(status: .uncertain, reason: "Camera cannot estimate attention reliably.",
                           calibrated: calibrated, observedAt: now)
        case .present, .facePresent:
            guard (evidence == .present && calibrated) || (evidence == .facePresent && !calibrated) else {
                return update(.uncertain, at: now, calibrated: calibrated)
            }
            if returnSince == nil { returnSince = now }
            let elapsed = now.timeIntervalSince(returnSince!)
            if elapsed >= Self.returnGrace {
                candidate = nil; candidateSince = nil; distracted = nil
                latest = .init(status: .present,
                               reason: calibrated ? "Facing the calibrated screen position." : "Face detected; calibrate to check gaze.",
                               calibrated: calibrated, observedAt: now, continuousSeconds: elapsed)
            } else if let distracted {
                latest = .init(status: distracted == .noFace ? .absent : .lookingAway, isDistracted: true,
                               reason: "Checking return to the screen.", calibrated: calibrated, observedAt: now,
                               continuousSeconds: elapsed, distractionReason: distracted)
            } else {
                candidate = nil; candidateSince = nil
                latest = .init(status: .uncertain, reason: "Checking screen attention.",
                               calibrated: calibrated, observedAt: now, continuousSeconds: elapsed)
            }
        case .lookingAway, .noFace:
            // Absence needs no calibration. A gaze judgment always does.
            guard evidence != .lookingAway || calibrated else {
                return update(.uncertain, at: now, calibrated: false)
            }
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
                           reason: reason == .noFace ? "No face detected by the camera." : "Looking away from the calibrated screen position.",
                           calibrated: calibrated, observedAt: now, continuousSeconds: elapsed,
                           distractionReason: reason)
        }
        return latest
    }

    public func snapshot(at now: Date) -> CameraAttentionSnapshot {
        guard let lastFrameAt, now >= lastFrameAt,
              now.timeIntervalSince(lastFrameAt) <= Self.maximumFrameGap else {
            return .init(status: .uncertain, reason: "Camera evidence is stale.",
                         calibrated: latest.calibrated, observedAt: lastFrameAt ?? .distantPast)
        }
        return latest
    }
}

/// Only numeric geometry survives a frame. Pupil Y uses eye width to reduce blink amplification.
public struct CameraGazeSample: Codable, Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var leftPupilX: Double
    public var leftPupilY: Double
    public var rightPupilX: Double
    public var rightPupilY: Double

    public init(yaw: Double, pitch: Double, leftPupilX: Double, leftPupilY: Double,
                rightPupilX: Double, rightPupilY: Double) {
        self.yaw = yaw; self.pitch = pitch
        self.leftPupilX = leftPupilX; self.leftPupilY = leftPupilY
        self.rightPupilX = rightPupilX; self.rightPupilY = rightPupilY
    }

    public var isValid: Bool {
        values.allSatisfy(\.isFinite) && abs(yaw) <= .pi / 2 && abs(pitch) <= .pi / 2
            && (0...1).contains(leftPupilX) && (0...1).contains(rightPupilX)
            && abs(leftPupilY) <= 0.4 && abs(rightPupilY) <= 0.4
    }

    fileprivate var values: [Double] { [yaw, pitch, leftPupilX, leftPupilY, rightPupilX, rightPupilY] }
}

public struct CameraGazeCalibration: Codable, Equatable, Sendable {
    public var baseline: CameraGazeSample
    public init(baseline: CameraGazeSample) { self.baseline = baseline }

    /// Conservative bands are heuristics, not an eye tracker or a screen-coordinate estimate.
    public func evidence(for sample: CameraGazeSample?) -> CameraAttentionEvidence {
        guard let sample, sample.isValid, baseline.isValid else { return .uncertain }
        let yaw = abs(sample.yaw - baseline.yaw), pitch = abs(sample.pitch - baseline.pitch)
        let lx = sample.leftPupilX - baseline.leftPupilX
        let rx = sample.rightPupilX - baseline.rightPupilX
        let ly = sample.leftPupilY - baseline.leftPupilY
        let ry = sample.rightPupilY - baseline.rightPupilY
        // Disagreeing eye estimates can be blinks, occlusion or faulty landmarks.
        guard abs(lx - rx) <= 0.18, abs(ly - ry) <= 0.12 else { return .uncertain }
        let x = abs((lx + rx) / 2), y = abs((ly + ry) / 2)
        if yaw >= 0.38 || pitch >= 0.30 || x >= 0.22 || y >= 0.14 { return .lookingAway }
        if yaw <= 0.22 && pitch <= 0.18 && x <= 0.12 && y <= 0.075 { return .present }
        return .uncertain
    }
}

/// Explicit calibration requires six consecutive stable, usable samples spanning 2.5 seconds.
public struct CameraGazeCalibrator: Sendable {
    private var samples: [(Date, CameraGazeSample)] = []
    public init() {}
    public var sampleCount: Int { samples.count }

    public mutating func add(_ sample: CameraGazeSample?, at now: Date) -> CameraGazeCalibration? {
        guard let sample, sample.isValid, abs(sample.yaw) < 0.40, abs(sample.pitch) < 0.35 else {
            samples.removeAll(); return nil
        }
        if let previous = samples.last,
           now <= previous.0 || now.timeIntervalSince(previous.0) > CameraAttentionPolicy.maximumFrameGap {
            samples.removeAll()
        }
        if let first = samples.first {
            let difference = zip(sample.values, first.1.values).map { abs($0 - $1) }
            if difference[0] > 0.12 || difference[1] > 0.12 || difference.dropFirst(2).contains(where: { $0 > 0.09 }) {
                samples.removeAll()
            }
        }
        samples.append((now, sample))
        if samples.count > 12 { samples.removeFirst(samples.count - 12) }
        guard samples.count >= 6, now.timeIntervalSince(samples[0].0) >= 2.5 else { return nil }
        let means = (0..<6).map { index in samples.map { $0.1.values[index] }.reduce(0, +) / Double(samples.count) }
        return .init(baseline: .init(yaw: means[0], pitch: means[1], leftPupilX: means[2], leftPupilY: means[3],
                                    rightPupilX: means[4], rightPupilY: means[5]))
    }
}
