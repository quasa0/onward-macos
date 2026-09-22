import Foundation
import CoreFoundation
import Darwin

public struct JevSpendReceipt: Sendable {
    public let inputTokens: Int64?
    public let estimatedNanodollars: Int64?

    public init(responseData: Data) {
        let object = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        let usage = object?["usage"] as? [String: Any]
        inputTokens = Self.integer(usage?["input_tokens"])
        // Verified 2026-09-22: $0.042 per million input tokens; output is free.
        // https://docs.typesafe.ai/models — aliases and unknown models are not priced.
        if object?["model"] as? String == "jev-1.13.0", let inputTokens,
           inputTokens <= Int64.max / 42 {
            estimatedNanodollars = inputTokens * 42
        } else { estimatedNanodollars = nil }
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
              let integer = Int64(number.stringValue), integer >= 0 else { return nil }
        return integer
    }
}

public struct JevSpendTotals: Codable, Equatable, Sendable {
    public private(set) var requestCount: Int64 = 0
    public private(set) var inputTokens: Int64 = 0
    public private(set) var estimatedNanodollars: Int64 = 0
    public private(set) var unpricedRequests: Int64 = 0
    public private(set) var unreportedRequests: Int64 = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case requestCount, inputTokens, estimatedNanodollars, unpricedRequests, unreportedRequests
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestCount = try values.decode(Int64.self, forKey: .requestCount)
        inputTokens = try values.decode(Int64.self, forKey: .inputTokens)
        estimatedNanodollars = try values.decode(Int64.self, forKey: .estimatedNanodollars)
        unpricedRequests = try values.decode(Int64.self, forKey: .unpricedRequests)
        unreportedRequests = try values.decode(Int64.self, forKey: .unreportedRequests)
        guard [requestCount, inputTokens, estimatedNanodollars, unpricedRequests, unreportedRequests].allSatisfy({ $0 >= 0 }),
              Self.add(unpricedRequests, unreportedRequests) <= requestCount else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid spend totals."))
        }
    }

    fileprivate mutating func record(_ receipt: JevSpendReceipt?) {
        requestCount = Self.add(requestCount, 1)
        if let receipt {
            inputTokens = Self.add(inputTokens, receipt.inputTokens ?? 0)
            estimatedNanodollars = Self.add(estimatedNanodollars, receipt.estimatedNanodollars ?? 0)
            if receipt.estimatedNanodollars == nil { unpricedRequests = Self.add(unpricedRequests, 1) }
        } else { unreportedRequests = Self.add(unreportedRequests, 1) }
    }

    fileprivate mutating func merge(_ other: Self) {
        requestCount = Self.add(requestCount, other.requestCount)
        inputTokens = Self.add(inputTokens, other.inputTokens)
        estimatedNanodollars = Self.add(estimatedNanodollars, other.estimatedNanodollars)
        unpricedRequests = Self.add(unpricedRequests, other.unpricedRequests)
        unreportedRequests = Self.add(unreportedRequests, other.unreportedRequests)
    }

    /// Persisted counters saturate rather than wrapping or trapping.
    private static func add(_ first: Int64, _ second: Int64) -> Int64 {
        let (sum, overflow) = first.addingReportingOverflow(second)
        return overflow ? .max : sum
    }
}

public struct JevSpendLedger: Codable, Equatable, Sendable {
    public let trackingStartedAt: Date
    public private(set) var dailyTotals: [String: JevSpendTotals] = [:]

    public init(trackingStartedAt: Date = Date()) { self.trackingStartedAt = trackingStartedAt }

    public var total: JevSpendTotals {
        dailyTotals.values.reduce(into: JevSpendTotals()) { $0.merge($1) }
    }
    public func today(at date: Date = Date(), calendar: Calendar = .current) -> JevSpendTotals {
        dailyTotals[Self.dayKey(date, calendar: calendar)] ?? JevSpendTotals()
    }
    public mutating func record(receipt: JevSpendReceipt, at date: Date, calendar: Calendar = .current) {
        dailyTotals[Self.dayKey(date, calendar: calendar), default: JevSpendTotals()].record(receipt)
    }
    public mutating func recordUnreported(at date: Date, calendar: Calendar = .current) {
        dailyTotals[Self.dayKey(date, calendar: calendar), default: JevSpendTotals()].record(nil)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = calendar.timeZone
        let parts = local.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private enum CodingKeys: String, CodingKey { case trackingStartedAt, dailyTotals }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trackingStartedAt = try values.decode(Date.self, forKey: .trackingStartedAt)
        dailyTotals = try values.decode([String: JevSpendTotals].self, forKey: .dailyTotals)
        guard trackingStartedAt.timeIntervalSince1970.isFinite,
              dailyTotals.keys.allSatisfy({ $0.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid spend ledger."))
        }
    }
}

public enum JevSpendFormat {
    /// Exact USD text, retaining enough decimal places for every nonzero amount.
    public static func usd(nanodollars: Int64) -> String {
        let amount = max(0, nanodollars)
        var fraction = String(format: "%09lld", amount % 1_000_000_000)
        while fraction.count > 2, fraction.last == "0" { fraction.removeLast() }
        return "$\(amount / 1_000_000_000).\(fraction)"
    }
}

public struct JevSpendFileStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url.standardizedFileURL }

    public func load() throws -> JevSpendLedger {
        try locked { try read(startedAt: Date()) }
    }
    @discardableResult public func record(receipt: JevSpendReceipt, at date: Date,
                                         calendar: Calendar = .current) throws -> JevSpendLedger {
        try update(at: date) { $0.record(receipt: receipt, at: date, calendar: calendar) }
    }
    @discardableResult public func recordUnreported(at date: Date,
                                                   calendar: Calendar = .current) throws -> JevSpendLedger {
        try update(at: date) { $0.recordUnreported(at: date, calendar: calendar) }
    }

    private func update(at date: Date, _ change: (inout JevSpendLedger) -> Void) throws -> JevSpendLedger {
        try locked {
            var ledger = try read(startedAt: date)
            change(&ledger)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try writeAtomically(encoder.encode(ledger))
            return ledger
        }
    }

    private func read(startedAt: Date) throws -> JevSpendLedger {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return JevSpendLedger(trackingStartedAt: startedAt)
        }
        do { return try JSONDecoder().decode(JevSpendLedger.self, from: data) }
        catch { throw StoreError.corruptLedger }
    }

    private func locked(_ action: () throws -> JevSpendLedger) throws -> JevSpendLedger {
        guard url.isFileURL else { throw StoreError.invalidURL }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Lock a stable sidecar inode: the ledger itself is replaced atomically.
        let descriptor = Darwin.open(url.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw Self.posixError() }
        }
        return try action()
    }

    private func writeAtomically(_ data: Data) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw Self.posixError() }
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private enum StoreError: LocalizedError {
        case corruptLedger, invalidURL
        var errorDescription: String? {
            switch self {
            case .corruptLedger: return "The spend ledger could not be read. Its existing contents were preserved."
            case .invalidURL: return "The spend ledger requires a local file URL."
            }
        }
    }
}
