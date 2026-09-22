import XCTest
import CoreGraphics
@testable import OnwardCore

final class AttentionPresenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)
    private let centered = CameraGazeSample(yaw: 0, pitch: 0, leftPupilX: 0.5, leftPupilY: 0,
                                          rightPupilX: 0.5, rightPupilY: 0)

    func testLookingAwayRequiresContinuousGraceAndFreshFrames() {
        var policy = CameraAttentionPolicy()
        for seconds in 0..<8 {
            XCTAssertFalse(policy.update(.lookingAway, at: start.addingTimeInterval(Double(seconds)), calibrated: true).isDistracted)
        }
        let confirmed = policy.update(.lookingAway, at: start.addingTimeInterval(8), calibrated: true)
        XCTAssertTrue(confirmed.isDistracted)
        XCTAssertEqual(confirmed.distractionReason, .lookingAway)
        XCTAssertFalse(policy.snapshot(at: start.addingTimeInterval(12)).isDistracted)
        XCTAssertEqual(policy.snapshot(at: start.addingTimeInterval(12)).status, .uncertain)
        XCTAssertFalse(policy.update(.lookingAway, at: start.addingTimeInterval(12), calibrated: true).isDistracted)
    }

    func testNoFaceGraceDoesNotRequireGazeCalibrationAndReturnDoesNotClaimGaze() {
        var policy = CameraAttentionPolicy()
        for seconds in 0..<12 {
            XCTAssertFalse(policy.update(.noFace, at: start.addingTimeInterval(Double(seconds)), calibrated: false).isDistracted)
        }
        XCTAssertTrue(policy.update(.noFace, at: start.addingTimeInterval(12), calibrated: false).isDistracted)
        XCTAssertTrue(policy.update(.facePresent, at: start.addingTimeInterval(13), calibrated: false).isDistracted)
        let recovered = policy.update(.facePresent, at: start.addingTimeInterval(14), calibrated: false)
        XCTAssertEqual(recovered.status, .present)
        XCTAssertFalse(recovered.isDistracted)
        XCTAssertFalse(recovered.calibrated)
        XCTAssertTrue(recovered.reason.contains("calibrate"))
    }

    func testUnknownBreaksContinuityAndCannotConfirmReturn() {
        var policy = CameraAttentionPolicy()
        for seconds in 0...8 { _ = policy.update(.lookingAway, at: start.addingTimeInterval(Double(seconds)), calibrated: true) }
        let unknown = policy.update(.uncertain, at: start.addingTimeInterval(9), calibrated: true)
        XCTAssertFalse(unknown.isDistracted)
        XCTAssertEqual(unknown.status, .uncertain)
        XCTAssertEqual(policy.update(.present, at: start.addingTimeInterval(10), calibrated: true).status, .uncertain)
        XCTAssertEqual(policy.update(.present, at: start.addingTimeInterval(11), calibrated: true).status, .present)
    }

    func testBriefReturnDoesNotEndConfirmedLookingAway() {
        var policy = CameraAttentionPolicy()
        for seconds in 0...8 { _ = policy.update(.lookingAway, at: start.addingTimeInterval(Double(seconds)), calibrated: true) }
        XCTAssertTrue(policy.update(.present, at: start.addingTimeInterval(9), calibrated: true).isDistracted)
        XCTAssertTrue(policy.update(.lookingAway, at: start.addingTimeInterval(9.5), calibrated: true).isDistracted)
        XCTAssertTrue(policy.update(.present, at: start.addingTimeInterval(10), calibrated: true).isDistracted)
        XCTAssertFalse(policy.update(.present, at: start.addingTimeInterval(11), calibrated: true).isDistracted)
    }

    func testBackwardClockAndLongFrameGapResetGrace() {
        var policy = CameraAttentionPolicy()
        for seconds in 0...8 { _ = policy.update(.lookingAway, at: start.addingTimeInterval(Double(seconds)), calibrated: true) }
        XCTAssertFalse(policy.update(.lookingAway, at: start, calibrated: true).isDistracted)
        XCTAssertFalse(policy.update(.lookingAway, at: start.addingTimeInterval(30), calibrated: true).isDistracted)
        XCTAssertFalse(policy.snapshot(at: start).isDistracted)
    }

    func testSwitchingAbsenceReasonStartsItsOwnGrace() {
        var policy = CameraAttentionPolicy()
        for seconds in 0...8 { _ = policy.update(.lookingAway, at: start.addingTimeInterval(Double(seconds)), calibrated: true) }
        let absent = policy.update(.noFace, at: start.addingTimeInterval(9), calibrated: true)
        XCTAssertFalse(absent.isDistracted)
        XCTAssertEqual(absent.continuousSeconds, 0)
        XCTAssertEqual(absent.distractionReason, .noFace)
    }

    func testUncalibratedGazeAndLandmarkFreeCalibratedFaceStayUnknown() {
        var policy = CameraAttentionPolicy()
        XCTAssertEqual(policy.update(.lookingAway, at: start, calibrated: false).status, .uncertain)
        XCTAssertEqual(policy.update(.present, at: start, calibrated: false).status, .uncertain)
        XCTAssertEqual(policy.update(.facePresent, at: start, calibrated: true).status, .uncertain)
    }

    func testSnapshotFreshnessBounds() {
        let snapshot = CameraAttentionSnapshot(status: .present, observedAt: start)
        XCTAssertTrue(snapshot.isFresh(at: start.addingTimeInterval(3)))
        XCTAssertFalse(snapshot.isFresh(at: start.addingTimeInterval(3.01)))
        XCTAssertFalse(snapshot.isFresh(at: start.addingTimeInterval(-1)))
    }

    func testSnapshotPreviewGeometryIsOptionalAndPreservesVisionCoordinates() {
        let empty = CameraAttentionSnapshot(status: .disabled)
        XCTAssertNil(empty.faceBounds)
        XCTAssertTrue(empty.pupilPoints.isEmpty)
        XCTAssertNil(empty.gazeOffset)
        XCTAssertEqual(empty.calibrationProgress, 0)
        XCTAssertNil(empty.calibrationSecondsRemaining)
        let face = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        let pupils = [CGPoint(x: 0.3, y: 0.6), CGPoint(x: 0.5, y: 0.6)]
        let snapshot = CameraAttentionSnapshot(status: .calibrating, faceBounds: face,
                                               pupilPoints: pupils, gazeOffset: CGPoint(x: -0.5, y: 0.25),
                                               calibrationProgress: 0.4, calibrationSecondsRemaining: 12)
        XCTAssertEqual(snapshot.faceBounds, face)
        XCTAssertEqual(snapshot.pupilPoints, pupils)
        XCTAssertEqual(snapshot.gazeOffset, CGPoint(x: -0.5, y: 0.25))
        XCTAssertEqual(snapshot.calibrationProgress, 0.4)
        XCTAssertEqual(snapshot.calibrationSecondsRemaining, 12)
    }

    func testDisplayGazeUsesUserRelativePupilDirectionAndClampsIt() throws {
        let calibration = CameraGazeCalibration(baseline: centered)
        XCTAssertEqual(calibration.gazeOffset(for: centered), .zero)
        var sample = centered
        sample.leftPupilX = 0.61; sample.rightPupilX = 0.61
        sample.leftPupilY = 0.07; sample.rightPupilY = 0.07
        let offset = try XCTUnwrap(calibration.gazeOffset(for: sample))
        XCTAssertEqual(offset.x, -0.5, accuracy: 0.0001)
        XCTAssertEqual(offset.y, 0.5, accuracy: 0.0001)
        sample.leftPupilX = 0; sample.rightPupilX = 0
        sample.leftPupilY = 0.4; sample.rightPupilY = 0.4
        XCTAssertEqual(calibration.gazeOffset(for: sample), CGPoint(x: 1, y: 1))
        sample.leftPupilX = 1; sample.rightPupilX = 1
        sample.leftPupilY = -0.4; sample.rightPupilY = -0.4
        XCTAssertEqual(calibration.gazeOffset(for: sample), CGPoint(x: -1, y: -1))
        sample = centered; sample.yaw = 0.7; sample.pitch = 0.5
        XCTAssertEqual(calibration.gazeOffset(for: sample), .zero)
        XCTAssertEqual(calibration.evidence(for: sample), .lookingAway)
    }

    func testDisplayGazeRejectsMissingInvalidAndDisagreeingEyes() {
        let calibration = CameraGazeCalibration(baseline: centered)
        XCTAssertNil(calibration.gazeOffset(for: nil))
        var sample = centered; sample.leftPupilX = 0.8
        XCTAssertNil(calibration.gazeOffset(for: sample))
        sample = centered; sample.rightPupilY = 0.2
        XCTAssertNil(calibration.gazeOffset(for: sample))
        sample = centered; sample.pitch = .nan
        XCTAssertNil(calibration.gazeOffset(for: sample))
        XCTAssertNil(CameraGazeCalibration(baseline: sample).gazeOffset(for: centered))
    }

    func testGazeUsesHeadPoseAndAgreedPupilsWithUnknownBand() {
        let calibration = CameraGazeCalibration(baseline: centered)
        XCTAssertEqual(calibration.evidence(for: centered), .present)
        var sample = centered
        sample.yaw = 0.5
        XCTAssertEqual(calibration.evidence(for: sample), .lookingAway)
        sample = centered; sample.pitch = 0.4
        XCTAssertEqual(calibration.evidence(for: sample), .lookingAway)
        sample = centered; sample.leftPupilX = 0.75; sample.rightPupilX = 0.75
        XCTAssertEqual(calibration.evidence(for: sample), .lookingAway)
        sample = centered; sample.leftPupilY = 0.16; sample.rightPupilY = 0.16
        XCTAssertEqual(calibration.evidence(for: sample), .lookingAway)
        sample = centered; sample.yaw = 0.3
        XCTAssertEqual(calibration.evidence(for: sample), .uncertain)
        sample = centered; sample.leftPupilX = 0.8
        XCTAssertEqual(calibration.evidence(for: sample), .uncertain)
        XCTAssertEqual(calibration.evidence(for: nil), .uncertain)
        sample = centered; sample.pitch = .nan
        XCTAssertEqual(calibration.evidence(for: sample), .uncertain)
    }

    func testCalibrationRequiresStableSamplesAndTimeSpan() {
        var calibrator = CameraGazeCalibrator()
        for index in 0..<5 { XCTAssertNil(calibrator.add(centered, at: start.addingTimeInterval(Double(index) * 0.5))) }
        XCTAssertEqual(calibrator.add(centered, at: start.addingTimeInterval(2.5))?.baseline, centered)
        var rushed = CameraGazeCalibrator()
        for index in 0..<12 { XCTAssertNil(rushed.add(centered, at: start.addingTimeInterval(Double(index) * 0.01))) }
    }

    func testCalibrationProgressRequiresBothSampleCountAndStableTime() {
        var calibrator = CameraGazeCalibrator()
        XCTAssertEqual(calibrator.progress, 0)
        for index in 0..<5 {
            XCTAssertNil(calibrator.add(centered, at: start.addingTimeInterval(Double(index) * 0.5)))
            XCTAssertEqual(calibrator.progress, Double(index) / 5, accuracy: 0.0001)
            XCTAssertLessThan(calibrator.progress, 1)
        }
        XCTAssertNotNil(calibrator.add(centered, at: start.addingTimeInterval(2.5)))
        XCTAssertEqual(calibrator.progress, 1)
        XCTAssertEqual(calibrator.reason, "Calibration complete.")
        var rushed = CameraGazeCalibrator()
        for index in 0..<12 {
            XCTAssertNil(rushed.add(centered, at: start.addingTimeInterval(Double(index) * 0.01)))
            XCTAssertLessThan(rushed.progress, 1)
        }
        var sparse = CameraGazeCalibrator()
        XCTAssertNil(sparse.add(centered, at: start))
        XCTAssertNil(sparse.add(centered, at: start.addingTimeInterval(2.5)))
        XCTAssertEqual(sparse.progress, 2.0 / 6, accuracy: 0.0001)
    }

    func testCalibrationProgressAndFeedbackResetForInvalidMovementAndInterruptedFrames() {
        var calibrator = CameraGazeCalibrator()
        for index in 0..<4 { _ = calibrator.add(centered, at: start.addingTimeInterval(Double(index) * 0.5)) }
        XCTAssertGreaterThan(calibrator.progress, 0)
        XCTAssertNil(calibrator.add(nil, at: start.addingTimeInterval(2)))
        XCTAssertEqual(calibrator.progress, 0)
        XCTAssertTrue(calibrator.reason.contains("eyes"))
        _ = calibrator.add(centered, at: start.addingTimeInterval(2.5))
        var moved = centered; moved.yaw = 0.2
        XCTAssertNil(calibrator.add(moved, at: start.addingTimeInterval(3)))
        XCTAssertEqual(calibrator.progress, 0)
        XCTAssertTrue(calibrator.reason.contains("Movement"))
        moved.yaw = 0.8
        XCTAssertNil(calibrator.add(moved, at: start.addingTimeInterval(3.5)))
        XCTAssertEqual(calibrator.progress, 0)
        XCTAssertTrue(calibrator.reason.contains("Face the screen"))
        _ = calibrator.add(centered, at: start.addingTimeInterval(4))
        _ = calibrator.add(centered, at: start.addingTimeInterval(4.5))
        XCTAssertNil(calibrator.add(centered, at: start.addingTimeInterval(8)))
        XCTAssertEqual(calibrator.progress, 0)
        XCTAssertTrue(calibrator.reason.contains("interrupted"))
    }

    func testCalibrationRejectsMissingEyesMovementAndOffCenterHeadPose() {
        var calibrator = CameraGazeCalibrator()
        _ = calibrator.add(centered, at: start)
        XCTAssertNil(calibrator.add(nil, at: start.addingTimeInterval(0.5)))
        XCTAssertEqual(calibrator.sampleCount, 0)
        _ = calibrator.add(centered, at: start.addingTimeInterval(1))
        var moved = centered; moved.yaw = 0.2
        XCTAssertNil(calibrator.add(moved, at: start.addingTimeInterval(1.5)))
        XCTAssertEqual(calibrator.sampleCount, 1)
        moved.yaw = 0.8
        XCTAssertNil(calibrator.add(moved, at: start.addingTimeInterval(2)))
        XCTAssertEqual(calibrator.sampleCount, 0)
    }

    func testCalibrationSurvivesNumericRoundTripWithoutImages() throws {
        let calibration = CameraGazeCalibration(baseline: centered)
        let data = try JSONEncoder().encode(calibration)
        XCTAssertLessThan(data.count, 300)
        XCTAssertEqual(try JSONDecoder().decode(CameraGazeCalibration.self, from: data), calibration)
    }
}
