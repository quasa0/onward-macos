import XCTest
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
