import Foundation
import Security
import OnwardCore

enum AppStorage {
    static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Onward", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static func append(_ entry: ActivityEntry) throws {
        let file = directory.appendingPathComponent("activity.jsonl")
        if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 10_000_000 {
            let previous = directory.appendingPathComponent("activity.previous.jsonl")
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            try FileManager.default.moveItem(at: file, to: previous)
        }
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: encoder.encode(entry) + Data([10]))
    }
    static func recentEntries() -> [ActivityEntry] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("activity.jsonl")), let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(150).compactMap { try? decoder.decode(ActivityEntry.self, from: Data($0.utf8)) }.reversed()
    }
}

enum Credentials {
    static let service = "com.quasa0.Onward.typesafe"
    static func read() -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "api-key", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String) throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "api-key"] as CFDictionary
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let updated = SecItemUpdate(query, [kSecValueData: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) }
        let status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "api-key", kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

final class JevClient: NSObject, URLSessionTaskDelegate {
    var onSpendRecorded: (@MainActor (JevSpendLedger?, String?) -> Void)?
    private let spendStore = JevSpendFileStore(url: AppStorage.directory.appendingPathComponent("jev-spend.json"))
    // Keep credentials on the documented host even if an upstream response redirects.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func classify(goal: String, context: String, observation: Observation, recent: [String], corrections: [String], key: String) async throws -> Judgment {
        try await classify(payload: JevContract.request(goal: goal, context: context, observation: observation, recent: recent, corrections: corrections), key: key)
    }
    func classify(payload: Data, key: String) async throws -> Judgment {
        guard !key.isEmpty else { throw JevError.missingKey }
        var request = URLRequest(url: JevContract.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        let start = Date()
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            await recordSpend(responseData: nil)
            throw error
        }
        guard let response = response as? HTTPURLResponse else { throw JevError.invalidResponse }
        // Account for returned usage before answer validation or foreground staleness checks.
        // A request can cost money even when its judgment is no longer usable.
        if response.statusCode == 200 { await recordSpend(responseData: data) }
        guard response.statusCode == 200 else { throw JevError.http(response.statusCode) }
        return try JevContract.parse(data, latencyMilliseconds: Int(Date().timeIntervalSince(start) * 1000))
    }
    private func recordSpend(responseData: Data?) async {
        do {
            let ledger: JevSpendLedger
            if let responseData { ledger = try spendStore.record(receipt: JevSpendReceipt(responseData: responseData), at: Date()) }
            else { ledger = try spendStore.recordUnreported(at: Date()) }
            await onSpendRecorded?(ledger, nil)
        } catch {
            await onSpendRecorded?(nil, "Jev usage could not be saved. The spend estimate may be incomplete.")
        }
    }
}
