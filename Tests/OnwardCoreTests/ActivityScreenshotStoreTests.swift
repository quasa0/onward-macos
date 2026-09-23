import XCTest
@testable import OnwardCore

final class ActivityScreenshotStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("onward-shots-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func age(_ id: UUID, _ store: ActivityScreenshotStore, seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000 + seconds)],
                                              ofItemAtPath: store.url(for: id).path)
    }

    func testSavesPrivateFileKeyedByObservation() throws {
        let store = ActivityScreenshotStore(directory: directory)
        let id = UUID()
        try store.save(Data([1, 2, 3]), for: id)
        XCTAssertTrue(store.contains(id)); XCTAssertFalse(store.contains(UUID()))
        XCTAssertEqual(try Data(contentsOf: store.url(for: id)), Data([1, 2, 3]))
        let file = try FileManager.default.attributesOfItem(atPath: store.url(for: id).path)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testRejectsEmptyAndOversizedImages() {
        let store = ActivityScreenshotStore(directory: directory, maximumBytes: 4)
        XCTAssertThrowsError(try store.save(Data(), for: UUID()))
        XCTAssertThrowsError(try store.save(Data(repeating: 1, count: 5), for: UUID()))
        XCTAssertThrowsError(try ActivityScreenshotStore(directory: directory, maximumCount: 0).save(Data([1]), for: UUID()))
    }

    func testCountLimitRemovesOldestOrdinaryImagesBeforeLearnedOnesAndKeepsNewest() throws {
        let store = ActivityScreenshotStore(directory: directory, maximumCount: 3)
        let learned = UUID(), old = UUID(), middle = UUID()
        for (offset, id) in [learned, old, middle].enumerated() {
            try store.save(Data([UInt8(offset + 1)]), for: id); try age(id, store, seconds: Double(offset))
        }
        let newest = UUID()
        try store.save(Data([9]), for: newest, learned: [learned])
        XCTAssertTrue(store.contains(learned)); XCTAssertFalse(store.contains(old))
        XCTAssertTrue(store.contains(middle)); XCTAssertTrue(store.contains(newest))
    }

    func testByteLimitCanEvictLearnedImagesOnlyAfterOrdinaryOnes() throws {
        let store = ActivityScreenshotStore(directory: directory, maximumBytes: 10)
        let learnedOld = UUID(), learnedNew = UUID(), ordinary = UUID()
        for (offset, id) in [learnedOld, learnedNew, ordinary].enumerated() {
            try store.save(Data(repeating: 1, count: 3), for: id, learned: [learnedOld, learnedNew])
            try age(id, store, seconds: Double(offset))
        }
        try store.save(Data(repeating: 2, count: 6), for: UUID(), learned: [learnedOld, learnedNew])
        XCTAssertFalse(store.contains(ordinary)); XCTAssertFalse(store.contains(learnedOld))
        XCTAssertTrue(store.contains(learnedNew))
    }

    func testPruningIgnoresUnrelatedFiles() throws {
        let store = ActivityScreenshotStore(directory: directory, maximumCount: 1)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unrelated = [directory.appendingPathComponent("notes.txt"), directory.appendingPathComponent("not-a-uuid.jpg")]
        for file in unrelated { try Data([1]).write(to: file) }
        try store.save(Data([1]), for: UUID()); try store.save(Data([2]), for: UUID())
        for file in unrelated { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        let managed = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { UUID(uuidString: String($0.dropLast(4))) != nil }
        XCTAssertEqual(managed.count, 1)
    }
}
