import XCTest
@testable import OnwardCore

final class JevSpendTests: XCTestCase {
    private func receipt(_ tokens: String = "1000", model: String = "jev-1.13.0") -> JevSpendReceipt {
        JevSpendReceipt(responseData: Data("{\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(tokens),\"output_tokens\":999999}}".utf8))
    }
    private func calendar(offset: Int = 0) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: offset)!
        return result
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testDocumentedInputPriceAndFreeOutputUseExactIntegerArithmetic() {
        let priced = receipt("1000000")
        XCTAssertEqual(priced.inputTokens, 1_000_000)
        XCTAssertEqual(priced.estimatedNanodollars, 42_000_000)
        XCTAssertEqual(receipt("1").estimatedNanodollars, 42)
        XCTAssertEqual(receipt("0").estimatedNanodollars, 0)
        XCTAssertEqual(JevSpendFormat.usd(nanodollars: 42_000_000), "$0.042")
    }

    func testUnknownModelAndMissingUsageRemainUnpriced() {
        let instant = date("2026-09-22T10:00:00Z")
        var ledger = JevSpendLedger(trackingStartedAt: instant)
        ledger.record(receipt: receipt("100", model: "jev-latest"), at: instant)
        ledger.record(receipt: receipt("200", model: "jev-2.0.0"), at: instant)
        ledger.record(receipt: JevSpendReceipt(responseData: Data(#"{"model":"jev-1.13.0"}"#.utf8)), at: instant)
        ledger.record(receipt: JevSpendReceipt(responseData: Data("not JSON".utf8)), at: instant)
        XCTAssertEqual(ledger.total.requestCount, 4)
        XCTAssertEqual(ledger.total.inputTokens, 300)
        XCTAssertEqual(ledger.total.estimatedNanodollars, 0)
        XCTAssertEqual(ledger.total.unpricedRequests, 4)
        XCTAssertEqual(ledger.total.unreportedRequests, 0)
    }

    func testStrictTokenParsingRejectsBooleansFractionsStringsNegativeAndOverflow() {
        for invalid in ["true", "false", "null", "\"123\"", "-1", "1.5", "1.0", "1e3",
                        "9007199254740993.1", "9223372036854775808", "18446744073709551616"] {
            XCTAssertNil(receipt(invalid).inputTokens, invalid)
            XCTAssertNil(receipt(invalid).estimatedNanodollars, invalid)
        }
        XCTAssertEqual(receipt("9007199254740993").inputTokens, 9_007_199_254_740_993)
        XCTAssertEqual(receipt(String(Int64.max)).inputTokens, .max)
        XCTAssertNil(receipt(String(Int64.max)).estimatedNanodollars, "Unrepresentable costs must not wrap.")
    }

    func testUnreportedAttemptsAreSeparateFromUnpricedResponses() {
        let instant = date("2026-09-22T10:00:00Z")
        var ledger = JevSpendLedger(trackingStartedAt: instant)
        ledger.record(receipt: receipt(), at: instant)
        ledger.recordUnreported(at: instant)
        XCTAssertEqual(ledger.total.requestCount, 2)
        XCTAssertEqual(ledger.total.inputTokens, 1000)
        XCTAssertEqual(ledger.total.estimatedNanodollars, 42_000)
        XCTAssertEqual(ledger.total.unpricedRequests, 0)
        XCTAssertEqual(ledger.total.unreportedRequests, 1)
    }

    func testLocalMidnightRolloverAndTrackingStartDoNotInventHistoricalUsage() {
        let first = date("2026-09-22T21:59:59Z"), second = date("2026-09-22T22:00:00Z")
        let local = calendar(offset: 2 * 3600)
        var ledger = JevSpendLedger(trackingStartedAt: first)
        XCTAssertEqual(ledger.total.requestCount, 0)
        XCTAssertTrue(ledger.dailyTotals.isEmpty)
        ledger.record(receipt: receipt("10"), at: first, calendar: local)
        ledger.record(receipt: receipt("20"), at: second, calendar: local)
        XCTAssertEqual(Set(ledger.dailyTotals.keys), ["2026-09-22", "2026-09-23"])
        XCTAssertEqual(ledger.today(at: first, calendar: local).inputTokens, 10)
        XCTAssertEqual(ledger.today(at: second, calendar: local).inputTokens, 20)
        XCTAssertEqual(ledger.today(at: date("2026-09-21T12:00:00Z"), calendar: local).requestCount, 0)
        XCTAssertEqual(ledger.total.inputTokens, 30)
        XCTAssertEqual(ledger.trackingStartedAt, first)
        var buddhist = Calendar(identifier: .buddhist); buddhist.timeZone = local.timeZone
        XCTAssertEqual(ledger.today(at: second, calendar: buddhist).inputTokens, 20)
    }

    func testTotalsSaturateInsteadOfOverflowingAndRemainDecodable() throws {
        let instant = date("2026-09-22T10:00:00Z")
        var ledger = JevSpendLedger(trackingStartedAt: instant)
        let maximumPriced = receipt(String(Int64.max / 42))
        for _ in 0..<50 { ledger.record(receipt: maximumPriced, at: instant) }
        XCTAssertEqual(ledger.total.requestCount, 50)
        XCTAssertEqual(ledger.total.inputTokens, .max)
        XCTAssertEqual(ledger.total.estimatedNanodollars, .max)
        XCTAssertEqual(try JSONDecoder().decode(JevSpendLedger.self, from: JSONEncoder().encode(ledger)), ledger)
    }

    func testSubcentUSDFormattingNeverRoundsNonzeroSpendToZero() {
        XCTAssertEqual(JevSpendFormat.usd(nanodollars: 0), "$0.00")
        XCTAssertEqual(JevSpendFormat.usd(nanodollars: 1), "$0.000000001")
        XCTAssertEqual(JevSpendFormat.usd(nanodollars: 42), "$0.000000042")
        XCTAssertEqual(JevSpendFormat.usd(nanodollars: 100_000), "$0.0001")
        XCTAssertEqual(JevSpendFormat.usd(nanodollars: 1_010_000_000), "$1.01")
        XCTAssertEqual(JevSpendFormat.usd(nanodollars: .max), "$9223372036.854775807")
    }

    private func temporaryStore() throws -> (URL, JevSpendFileStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("onward-spend-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, JevSpendFileStore(url: directory.appendingPathComponent("spend.json")))
    }

    func testStoreStartsEmptyAndReloadsExactTotalsAcrossInstances() throws {
        let (_, store) = try temporaryStore()
        XCTAssertEqual(try store.load().total.requestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        let instant = date("2026-09-22T10:00:00Z")
        let first = try store.record(receipt: receipt(), at: instant)
        XCTAssertEqual(first.trackingStartedAt, instant)
        let another = JevSpendFileStore(url: store.url)
        let updated = try another.recordUnreported(at: instant)
        XCTAssertEqual(try store.load(), updated)
        XCTAssertEqual(updated.total.requestCount, 2)
        XCTAssertEqual(updated.total.unreportedRequests, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testIndependentConcurrentWritersDoNotLoseUpdates() throws {
        let (_, store) = try temporaryStore()
        let instant = date("2026-09-22T10:00:00Z"), priced = receipt("7")
        let errors = Errors()
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            do { try JevSpendFileStore(url: store.url).record(receipt: priced, at: instant) }
            catch { errors.append(error) }
        }
        XCTAssertEqual(errors.count, 0)
        let total = try store.load().total
        XCTAssertEqual(total.requestCount, 40)
        XCTAssertEqual(total.inputTokens, 280)
        XCTAssertEqual(total.estimatedNanodollars, 11_760)
    }

    func testSidecarLockSerializesAgainstAnIndependentProcess() throws {
        let (_, store) = try temporaryStore()
        let child = Process(), ready = Pipe(), release = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,signal,sys; signal.alarm(5); f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.read(1)", store.url.appendingPathExtension("lock").path]
        child.standardOutput = ready; child.standardInput = release
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        XCTAssertEqual(ready.fileHandleForReading.readData(ofLength: 6), Data("ready\n".utf8))
        let finished = DispatchSemaphore(value: 0), errors = Errors()
        let priced = receipt(), instant = date("2026-09-22T10:00:00Z")
        DispatchQueue.global().async {
            do { try store.record(receipt: priced, at: instant) } catch { errors.append(error) }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        try release.fileHandleForWriting.write(contentsOf: Data([10]))
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(errors.count, 0)
        XCTAssertEqual(try store.load().total.requestCount, 1)
    }

    func testCorruptOrInvalidLedgerIsPreservedWithoutReplacement() throws {
        let (directory, store) = try temporaryStore()
        let instant = date("2026-09-22T10:00:00Z")
        let invalidTotals = #"{"trackingStartedAt":0,"dailyTotals":{"2026-09-22":{"requestCount":1,"inputTokens":-1,"estimatedNanodollars":0,"unpricedRequests":0,"unreportedRequests":0}}}"#
        for text in ["broken JSON", "{}", invalidTotals] {
            let original = Data(text.utf8)
            try original.write(to: store.url)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.record(receipt: receipt(), at: instant))
            XCTAssertThrowsError(try store.recordUnreported(at: instant))
            XCTAssertEqual(try Data(contentsOf: store.url), original)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
    }

    private final class Errors: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Error] = []
        func append(_ error: Error) { lock.lock(); defer { lock.unlock() }; values.append(error) }
        var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    }
}
