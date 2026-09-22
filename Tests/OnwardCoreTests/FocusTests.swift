import XCTest
@testable import OnwardCore

final class FocusTests: XCTestCase {
    let epoch = Date(timeIntervalSince1970: 1_000)
    func judgment(_ alignment: Alignment, probability: Double = 0.95) -> Judgment {
        var probabilities = Dictionary(uniqueKeysWithValues: Alignment.allCases.map { ($0.rawValue, (1 - probability) / 3) })
        probabilities[alignment.rawValue] = probability
        return Judgment(alignment: alignment, probabilities: probabilities, confidence: 0.9)
    }
    func testDistractionRequiresContinuousFreshEvidence() {
        var policy = FocusPolicy()
        policy.accept(judgment(.offGoal), at: epoch)
        XCTAssertEqual(policy.status(at: epoch), .drifting)
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(20))
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(40))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(46)), .distracted)
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(71)), .observing)
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(80))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(80)), .drifting)
    }
    func testUncertaintyHoldsColorAndReturningToGoalClearsDistraction() {
        var policy = FocusPolicy()
        policy.accept(judgment(.offGoal), at: epoch)
        policy.accept(judgment(.unclear, probability: 0.4), at: epoch.addingTimeInterval(10))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(10)), .drifting)
        XCTAssertEqual(policy.alignment, .unclear)
        XCTAssertTrue(policy.isHoldingStatus)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(20)), 10)
        policy.accept(judgment(.supporting), at: epoch.addingTimeInterval(20))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(20)), .focused)
        XCTAssertFalse(policy.isHoldingStatus)
        XCTAssertNil(policy.offGoalSince)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(20)), 0)
        policy.reset()
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(21)), .observing)
    }
    func testReportedOffGoalProbabilitiesEscalateAndRecover() {
        var policy = FocusPolicy()
        // These sub-0.65 choices were previously rewritten to unclear despite selecting off_goal.
        let samples: [(TimeInterval, Double)] = [(0, 0.47), (15, 0.64), (30, 0.48), (45, 0.44), (60, 0.64)]
        for (seconds, probability) in samples {
            let time = epoch.addingTimeInterval(seconds)
            policy.accept(judgment(.offGoal, probability: probability), at: time)
            XCTAssertEqual(policy.status(at: time), seconds < 45 ? .drifting : .distracted)
            XCTAssertEqual(policy.offGoalSince, epoch)
        }
        policy.accept(judgment(.onGoal, probability: 0.93), at: epoch.addingTimeInterval(61))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(61)), .focused)
        XCTAssertNil(policy.offGoalSince)
        policy.accept(judgment(.offGoal, probability: 0.44), at: epoch.addingTimeInterval(62))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(62)), .drifting)
        policy.accept(judgment(.unclear, probability: 0.4), at: epoch.addingTimeInterval(63))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(63)), .drifting)
        XCTAssertTrue(policy.isHoldingStatus)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(63)), 1)
        policy.accept(judgment(.offGoal, probability: 0.48), at: epoch.addingTimeInterval(64))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(95)), .observing)
        policy.accept(judgment(.offGoal, probability: 0.47), at: epoch.addingTimeInterval(96))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(96)), .drifting)
        XCTAssertEqual(policy.offGoalSince, epoch.addingTimeInterval(96))
    }
    func testFirstUncertaintyStaysNeutralAndGreenSurvivesRepeatedUncertainty() {
        var policy = FocusPolicy()
        policy.acceptUncertainty(at: epoch)
        XCTAssertEqual(policy.status(at: epoch), .unclear)
        XCTAssertEqual(policy.alignment, .unclear)
        XCTAssertFalse(policy.isHoldingStatus)
        XCTAssertEqual(policy.offGoalDuration(at: epoch), 0)
        policy.accept(judgment(.onGoal), at: epoch.addingTimeInterval(1))
        for seconds in [5.0, 25, 45, 65] {
            let time = epoch.addingTimeInterval(seconds)
            policy.acceptUncertainty(at: time)
            XCTAssertEqual(policy.status(at: time), .focused)
            XCTAssertEqual(policy.alignment, .unclear)
            XCTAssertTrue(policy.isHoldingStatus)
            XCTAssertEqual(policy.offGoalDuration(at: time), 0)
        }
    }
    func testRepeatedUncertaintyFreezesYellowAndOffGoalResumesWithoutUncertainTime() {
        var policy = FocusPolicy()
        policy.accept(judgment(.offGoal), at: epoch)
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(20))
        for seconds in [44.0, 60, 80, 100] {
            let time = epoch.addingTimeInterval(seconds)
            policy.acceptUncertainty(at: time)
            XCTAssertEqual(policy.status(at: time), .drifting)
            XCTAssertEqual(policy.offGoalDuration(at: time), 44)
            XCTAssertTrue(policy.isHoldingStatus)
        }
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(105))
        XCTAssertFalse(policy.isHoldingStatus)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(105)), 44)
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(105)), .drifting)
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(106)), .distracted)
        // A second uncertain interval must also be excluded after resuming.
        policy.acceptUncertainty(at: epoch.addingTimeInterval(107))
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(120))
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(120)), 46)
    }
    func testRedAndItsDurationRemainFrozenDuringUncertainty() {
        var policy = FocusPolicy()
        for seconds in [0.0, 20, 40] { policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(seconds)) }
        for seconds in [46.0, 60, 80, 100] {
            let time = epoch.addingTimeInterval(seconds)
            policy.accept(judgment(.unclear), at: time)
            XCTAssertEqual(policy.status(at: time), .distracted)
            XCTAssertEqual(policy.offGoalDuration(at: time), 46)
            XCTAssertTrue(policy.isHoldingStatus)
        }
        policy.accept(judgment(.onGoal), at: epoch.addingTimeInterval(101))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(101)), .focused)
        XCTAssertFalse(policy.isHoldingStatus)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(101)), 0)
    }
    func testStaleGapAndResetClearHeldStatusAndPausedTime() {
        var policy = FocusPolicy()
        policy.accept(judgment(.offGoal), at: epoch)
        policy.acceptUncertainty(at: epoch.addingTimeInterval(20))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(51)), .observing)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(51)), 0)
        policy.acceptUncertainty(at: epoch.addingTimeInterval(52))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(52)), .unclear)
        XCTAssertFalse(policy.isHoldingStatus)
        XCTAssertNil(policy.offGoalSince)
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(53))
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(53)), 0)
        policy.acceptUncertainty(at: epoch.addingTimeInterval(54))
        policy.reset()
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(54)), .observing)
        XCTAssertFalse(policy.isHoldingStatus)
        XCTAssertNil(policy.offGoalSince)
        XCTAssertNil(policy.lastJudgmentAt)
        policy.acceptUncertainty(at: epoch.addingTimeInterval(55))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(55)), .unclear)
    }
    func testCheckingThenUnclearKeepsTheOriginalPauseTime() {
        var policy = FocusPolicy()
        policy.accept(judgment(.offGoal), at: epoch)
        policy.suspend(at: epoch.addingTimeInterval(10))
        policy.suspend(at: epoch.addingTimeInterval(15))
        XCTAssertEqual(policy.alignment, .offGoal)
        XCTAssertEqual(policy.lastJudgmentAt, epoch)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(20)), 10)
        policy.acceptUncertainty(at: epoch.addingTimeInterval(20))
        policy.acceptUncertainty(at: epoch.addingTimeInterval(40))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(40)), .drifting)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(40)), 10)
        XCTAssertEqual(policy.alignment, .unclear)
        XCTAssertTrue(policy.isHoldingStatus)
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(50))
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(50)), 10)
    }
    func testCheckingThenOffGoalResumesWithoutCountingTheCheckingGap() {
        var policy = FocusPolicy()
        policy.accept(judgment(.offGoal), at: epoch)
        policy.suspend(at: epoch.addingTimeInterval(10))
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(30))
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(30)), 10)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(40)), 20)
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(40)), .drifting)
        XCTAssertFalse(policy.isHoldingStatus)
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(50))
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(65)), 45)
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(65)), .distracted)
    }
    func testCheckingDoesNotRefreshEvidenceOrCarryTimeAcrossAStaleGap() {
        var policy = FocusPolicy()
        policy.accept(judgment(.offGoal), at: epoch)
        policy.suspend(at: epoch.addingTimeInterval(20))
        policy.suspend(at: epoch.addingTimeInterval(29))
        XCTAssertEqual(policy.alignment, .offGoal)
        XCTAssertEqual(policy.lastJudgmentAt, epoch)
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(31)), .observing)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(31)), 0)
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(40))
        XCTAssertEqual(policy.offGoalSince, epoch.addingTimeInterval(40))
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(40)), 0)
        policy.reset()
        policy.suspend(at: epoch.addingTimeInterval(41))
        XCTAssertNil(policy.lastJudgmentAt)
        XCTAssertNil(policy.offGoalSince)
        XCTAssertEqual(policy.alignment, .unclear)
    }
    func testVerifiedCheckingCompletionResumesFreshJudgmentWithoutRefreshingIt() {
        var policy = FocusPolicy(); policy.redAfter = 30
        policy.accept(judgment(.offGoal), at: epoch)
        policy.suspend(at: epoch.addingTimeInterval(5))
        policy.resume(at: epoch.addingTimeInterval(7))
        policy.resume(at: epoch.addingTimeInterval(12))
        XCTAssertEqual(policy.lastJudgmentAt, epoch)
        XCTAssertEqual(policy.alignment, .offGoal)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(20)), 18)
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(20))
        policy.suspend(at: epoch.addingTimeInterval(22))
        policy.resume(at: epoch.addingTimeInterval(24))
        XCTAssertEqual(policy.lastJudgmentAt, epoch.addingTimeInterval(20))
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(33)), .drifting)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(34)), 30)
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(34)), .distracted)
    }
    func testVerifiedSurfaceCannotResumeExplicitUncertainty() {
        var policy = FocusPolicy()
        policy.accept(judgment(.offGoal), at: epoch)
        policy.suspend(at: epoch.addingTimeInterval(5))
        policy.acceptUncertainty(at: epoch.addingTimeInterval(7))
        policy.resume(at: epoch.addingTimeInterval(10))
        policy.acceptUncertainty(at: epoch.addingTimeInterval(25))
        policy.resume(at: epoch.addingTimeInterval(26))
        XCTAssertEqual(policy.lastJudgmentAt, epoch.addingTimeInterval(25))
        XCTAssertEqual(policy.alignment, .unclear)
        XCTAssertTrue(policy.isHoldingStatus)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(30)), 5)
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(35))
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(36)), 6)
    }
    func testVerifiedSurfaceCannotResumeStaleJudgmentOrCarryItsPausedTime() {
        var policy = FocusPolicy()
        policy.accept(judgment(.offGoal), at: epoch)
        policy.suspend(at: epoch.addingTimeInterval(20))
        policy.resume(at: epoch.addingTimeInterval(31))
        XCTAssertEqual(policy.lastJudgmentAt, epoch)
        XCTAssertEqual(policy.status(at: epoch.addingTimeInterval(31)), .observing)
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(31)), 0)
        policy.accept(judgment(.offGoal), at: epoch.addingTimeInterval(40))
        XCTAssertEqual(policy.offGoalSince, epoch.addingTimeInterval(40))
        XCTAssertEqual(policy.offGoalDuration(at: epoch.addingTimeInterval(41)), 1)
    }
    func testNearlyFlatProbabilitiesStillHonorTheSelectedCategory() {
        let expected: [Alignment: FocusStatus] = [.onGoal: .focused, .supporting: .focused,
                                                  .offGoal: .drifting, .unclear: .unclear]
        for alignment in Alignment.allCases {
            var policy = FocusPolicy()
            let choice = judgment(alignment, probability: 0.251)
            policy.accept(choice, at: epoch)
            XCTAssertEqual(policy.alignment, alignment)
            XCTAssertEqual(policy.status(at: epoch), expected[alignment])
            XCTAssertEqual(choice.probability, 0.251)
        }
    }
    func testFingerprintIgnoresTimestampsButTracksContentAndURL() {
        var a = Observation(); a.appName = "Helium"; a.url = "https://example.com/a"; a.ocrText = "First"
        var b = a; b.id = UUID(); b.capturedAt = epoch; b.captureMilliseconds = 20
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        b.url = "https://example.com/b"; XCTAssertNotEqual(a.fingerprint, b.fingerprint)
        b = a; b.ocrText = "Changed"; XCTAssertNotEqual(a.fingerprint, b.fingerprint)
    }
    func testUnicodeByteLimitNeverProducesInvalidText() {
        for limit in 0...20 {
            let output = boundedText("abc🧭é漢字def", bytes: limit)
            XCTAssertLessThanOrEqual(output.utf8.count, limit)
            XCTAssertTrue("abc🧭é漢字def".hasPrefix(output))
        }
    }
    func testJevRequestContainsTextAndExactURLWithoutCredentialsOrImages() throws {
        var observation = Observation(); observation.url = "https://example.com/path?q=exact#anchor"; observation.ocrText = "Local text"
        let data = try JevContract.request(goal: "Build Onward", context: "Allow research", observation: observation, recent: [], corrections: [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? [String: Any]); let current = try XCTUnwrap(state["current"] as? [String: Any])
        XCTAssertEqual(current["url"] as? String, observation.url)
        XCTAssertEqual(current["ocrText"] as? String, "Local text")
        XCTAssertNil(current["screenshot"]); XCTAssertNil(object["apiKey"])
        XCTAssertEqual(state["active_goal"] as? String, "Build Onward")
    }
    func testMalformedModelProbabilitiesAreRejected() throws {
        let invalid: [String: Any] = ["model": "jev", "answers": ["alignment": ["type": "choice", "choice": "off_goal", "confidence": 0.8, "probabilities": ["off_goal": 0.99]]]]
        XCTAssertThrowsError(try JevContract.parse(JSONSerialization.data(withJSONObject: invalid), latencyMilliseconds: 1))
        let valid: [String: Any] = ["model": "jev", "answers": ["alignment": ["type": "choice", "choice": "off_goal", "confidence": 0.9, "probabilities": ["off_goal": 0.9, "on_goal": 0.05, "supporting": 0.03, "unclear": 0.02]]], "usage": ["input_tokens": 100]]
        let parsed = try JevContract.parse(JSONSerialization.data(withJSONObject: valid), latencyMilliseconds: 10)
        XCTAssertEqual(parsed.alignment, .offGoal); XCTAssertEqual(parsed.probability, 0.9)
    }
}
