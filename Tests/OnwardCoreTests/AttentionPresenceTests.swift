import XCTest
import CoreGraphics
@testable import OnwardCore

final class AttentionPresenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)

    func testLookingAwayRequiresContinuousGraceAndFreshFrames() {
        var policy = CameraAttentionPolicy()
        for seconds in 0..<8 {
            XCTAssertFalse(policy.update(.lookingAway, at: start.addingTimeInterval(Double(seconds))).isDistracted)
        }
        let confirmed = policy.update(.lookingAway, at: start.addingTimeInterval(8))
        XCTAssertTrue(confirmed.isDistracted)
        XCTAssertEqual(confirmed.distractionReason, .lookingAway)
        XCTAssertFalse(policy.snapshot(at: start.addingTimeInterval(12)).isDistracted)
        XCTAssertEqual(policy.snapshot(at: start.addingTimeInterval(12)).status, .uncertain)
        XCTAssertFalse(policy.update(.lookingAway, at: start.addingTimeInterval(12)).isDistracted)
    }

    func testNoFaceGraceAndReturnNeedsOneSecondFacing() {
        var policy = CameraAttentionPolicy()
        for seconds in 0..<12 {
            XCTAssertFalse(policy.update(.noFace, at: start.addingTimeInterval(Double(seconds))).isDistracted)
        }
        XCTAssertTrue(policy.update(.noFace, at: start.addingTimeInterval(12)).isDistracted)
        XCTAssertTrue(policy.update(.present, at: start.addingTimeInterval(13)).isDistracted)
        let recovered = policy.update(.present, at: start.addingTimeInterval(14))
        XCTAssertEqual(recovered.status, .present)
        XCTAssertFalse(recovered.isDistracted)
    }

    func testUnknownBreaksContinuityAndCannotConfirmReturn() {
        var policy = CameraAttentionPolicy()
        for seconds in 0...8 { _ = policy.update(.lookingAway, at: start.addingTimeInterval(Double(seconds))) }
        let unknown = policy.update(.uncertain, at: start.addingTimeInterval(9), uncertainReason: "Specific reason")
        XCTAssertFalse(unknown.isDistracted)
        XCTAssertEqual(unknown.status, .uncertain)
        XCTAssertEqual(unknown.reason, "Specific reason")
        XCTAssertEqual(policy.update(.present, at: start.addingTimeInterval(10)).status, .uncertain)
        XCTAssertEqual(policy.update(.present, at: start.addingTimeInterval(11)).status, .present)
    }

    func testBriefReturnDoesNotEndConfirmedLookingAway() {
        var policy = CameraAttentionPolicy()
        for seconds in 0...8 { _ = policy.update(.lookingAway, at: start.addingTimeInterval(Double(seconds))) }
        XCTAssertTrue(policy.update(.present, at: start.addingTimeInterval(9)).isDistracted)
        XCTAssertTrue(policy.update(.lookingAway, at: start.addingTimeInterval(9.5)).isDistracted)
        XCTAssertTrue(policy.update(.present, at: start.addingTimeInterval(10)).isDistracted)
        XCTAssertFalse(policy.update(.present, at: start.addingTimeInterval(11)).isDistracted)
    }

    func testBackwardClockAndLongFrameGapResetGrace() {
        var policy = CameraAttentionPolicy()
        for seconds in 0...8 { _ = policy.update(.lookingAway, at: start.addingTimeInterval(Double(seconds))) }
        XCTAssertFalse(policy.update(.lookingAway, at: start).isDistracted)
        XCTAssertFalse(policy.update(.lookingAway, at: start.addingTimeInterval(30)).isDistracted)
        XCTAssertFalse(policy.snapshot(at: start).isDistracted)
    }

    func testSwitchingAbsenceReasonStartsItsOwnGrace() {
        var policy = CameraAttentionPolicy()
        for seconds in 0...8 { _ = policy.update(.lookingAway, at: start.addingTimeInterval(Double(seconds))) }
        let absent = policy.update(.noFace, at: start.addingTimeInterval(9))
        XCTAssertFalse(absent.isDistracted)
        XCTAssertEqual(absent.continuousSeconds, 0)
        XCTAssertEqual(absent.distractionReason, .noFace)
    }

    func testSnapshotFreshnessBounds() {
        let snapshot = CameraAttentionSnapshot(status: .present, observedAt: start)
        XCTAssertTrue(snapshot.isFresh(at: start.addingTimeInterval(3)))
        XCTAssertFalse(snapshot.isFresh(at: start.addingTimeInterval(3.01)))
        XCTAssertFalse(snapshot.isFresh(at: start.addingTimeInterval(-1)))
    }
}

final class HeadPoseBaselineTests: XCTestCase {
    private func learned(_ center: HeadPose = HeadPose(yaw: 0.1, pitch: -0.2)) -> HeadPoseBaseline {
        var baseline = HeadPoseBaseline()
        for _ in 0..<HeadPoseBaseline.learningSamples { _ = baseline.classify(center) }
        return baseline
    }

    func testLearnsUsualDirectionWithoutCalibrationAndStaysUnknownUntilThen() {
        var baseline = HeadPoseBaseline()
        for _ in 0..<(HeadPoseBaseline.learningSamples - 1) {
            XCTAssertEqual(baseline.classify(HeadPose(yaw: 0.1, pitch: -0.2)), .uncertain)
        }
        XCTAssertFalse(baseline.isReady)
        _ = baseline.classify(HeadPose(yaw: 0.1, pitch: -0.2))
        XCTAssertEqual(baseline.center, HeadPose(yaw: 0.1, pitch: -0.2))
        XCTAssertEqual(baseline.classify(HeadPose(yaw: 0.2, pitch: -0.1)), .present)
    }

    func testLearningIgnoresStronglyTurnedPosesAndInvalidInput() {
        var baseline = HeadPoseBaseline()
        for _ in 0..<10 { XCTAssertEqual(baseline.classify(HeadPose(yaw: 0.9, pitch: 0)), .uncertain) }
        XCTAssertFalse(baseline.isReady)
        XCTAssertEqual(baseline.classify(HeadPose(yaw: .nan, pitch: 0)), .uncertain)
        XCTAssertEqual(baseline.classify(HeadPose(yaw: 2, pitch: 0)), .uncertain)
    }

    func testOnlyLargeTurnsCountAndTheMiddleBandIsUncertain() {
        var baseline = learned()
        XCTAssertEqual(baseline.classify(HeadPose(yaw: 0.1 + 0.65, pitch: -0.2)), .lookingAway)
        XCTAssertEqual(baseline.classify(HeadPose(yaw: 0.1, pitch: -0.2 - 0.55)), .lookingAway)
        XCTAssertEqual(baseline.classify(HeadPose(yaw: 0.1 - 0.5, pitch: -0.2)), .uncertain)
        XCTAssertEqual(baseline.classify(HeadPose(yaw: 0.1 + 0.3, pitch: -0.2 + 0.2)), .present)
    }

    func testLookingAwayNeverDragsTheCenter() {
        var baseline = learned()
        for _ in 0..<200 { _ = baseline.classify(HeadPose(yaw: 1.2, pitch: 0.4)) }
        XCTAssertEqual(baseline.center, HeadPose(yaw: 0.1, pitch: -0.2))
        for _ in 0..<200 { _ = baseline.classify(HeadPose(yaw: 0.3, pitch: -0.2)) }
        XCTAssertEqual(baseline.center?.yaw ?? 0, 0.3, accuracy: 0.01)
    }

    func testExplicitDirectionUsesMedianOfRecentPoses() {
        var baseline = learned()
        XCTAssertFalse(baseline.setCenter(from: [HeadPose(yaw: 0.8, pitch: 0)]))
        XCTAssertTrue(baseline.setCenter(from: [HeadPose(yaw: 0.8, pitch: 0.1), HeadPose(yaw: 0.9, pitch: 0.1), HeadPose(yaw: 3, pitch: 0)]))
        XCTAssertEqual(baseline.center?.yaw ?? 0, 0.85, accuracy: 0.0001)
        XCTAssertEqual(baseline.classify(HeadPose(yaw: 0.85, pitch: 0.1)), .present)
        let offset = try? XCTUnwrap(baseline.offset(for: HeadPose(yaw: 0.85 + HeadPoseBaseline.awayYaw, pitch: 0.1)))
        XCTAssertEqual(offset?.x ?? 0, 1, accuracy: 0.0001)
    }

    func testPersistedCenterRoundTripsAndInvalidCenterIsDropped() throws {
        let data = try JSONEncoder().encode(HeadPose(yaw: 0.2, pitch: -0.1))
        XCTAssertTrue(HeadPoseBaseline(center: try JSONDecoder().decode(HeadPose.self, from: data)).isReady)
        XCTAssertFalse(HeadPoseBaseline(center: HeadPose(yaw: .infinity, pitch: 0)).isReady)
    }
}

final class CameraBodyCueTests: XCTestCase {
    private let shoulders: [CameraBodyJoint: CGPoint] = [.leftShoulder: CGPoint(x: 0.3, y: 0.2), .rightShoulder: CGPoint(x: 0.7, y: 0.2)]

    private func joints(_ extra: [CameraBodyJoint: CGPoint]) -> [CameraBodyJoint: CGPoint] {
        shoulders.merging(extra) { $1 }
    }

    func testClassifiesFacingTurnedAndAbsent() {
        XCTAssertEqual(CameraBodyCue(joints: [:]), .none)
        XCTAssertEqual(CameraBodyCue(joints: joints([.nose: CGPoint(x: 0.5, y: 0.5), .leftEye: CGPoint(x: 0.47, y: 0.53), .rightEye: CGPoint(x: 0.53, y: 0.53)])), .facing)
        // Back of the head: shoulders and ears, no facial features.
        XCTAssertEqual(CameraBodyCue(joints: joints([.leftEar: CGPoint(x: 0.45, y: 0.5)])), .turnedAway)
        // Profile: nose, one eye, one ear.
        XCTAssertEqual(CameraBodyCue(joints: joints([.nose: CGPoint(x: 0.4, y: 0.5), .rightEye: CGPoint(x: 0.43, y: 0.53), .rightEar: CGPoint(x: 0.52, y: 0.52)])), .turnedAway)
        // Face features visible but far outside the shoulders: a strong turn.
        XCTAssertEqual(CameraBodyCue(joints: joints([.nose: CGPoint(x: 0.95, y: 0.5), .leftEye: CGPoint(x: 0.92, y: 0.53), .rightEye: CGPoint(x: 0.97, y: 0.53)])), .turnedAway)
        XCTAssertEqual(CameraBodyCue(joints: [.nose: CGPoint(x: 0.5, y: 0.5)]), .unclear)
    }

    func testEstimateUsesFaceFirstAndBodyOnlyWithoutAUsableFace() {
        var baseline = HeadPoseBaseline(center: HeadPose(yaw: 0, pitch: 0))
        XCTAssertEqual(CameraAttentionEstimate.evidence(faceCount: 1, pose: HeadPose(yaw: 0.05, pitch: 0), body: .turnedAway, baseline: &baseline), .present)
        XCTAssertEqual(CameraAttentionEstimate.evidence(faceCount: 1, pose: HeadPose(yaw: 0.9, pitch: 0), body: .none, baseline: &baseline), .lookingAway)
        XCTAssertEqual(CameraAttentionEstimate.evidence(faceCount: 0, pose: nil, body: .turnedAway, baseline: &baseline), .lookingAway)
        XCTAssertEqual(CameraAttentionEstimate.evidence(faceCount: 0, pose: nil, body: .none, baseline: &baseline), .noFace)
        XCTAssertEqual(CameraAttentionEstimate.evidence(faceCount: 0, pose: nil, body: .facing, baseline: &baseline), .uncertain)
        XCTAssertEqual(CameraAttentionEstimate.evidence(faceCount: 1, pose: nil, body: .none, baseline: &baseline), .uncertain)
        XCTAssertEqual(CameraAttentionEstimate.evidence(faceCount: 2, pose: HeadPose(yaw: 0, pitch: 0), body: .none, baseline: &baseline), .uncertain)
    }
}
