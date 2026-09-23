import Foundation

/// Local review images are keyed to the exact observation, never to a changing window title.
/// Only JPEG files named by a UUID are managed; other files in the directory are left alone.
public struct ActivityScreenshotStore: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case invalidImage
        public var errorDescription: String? { "The window screenshot was empty or larger than the storage limit." }
    }
    public let directory: URL
    public let maximumBytes: Int
    public let maximumCount: Int
    public init(directory: URL, maximumBytes: Int = 256_000_000, maximumCount: Int = 1500) {
        self.directory = directory; self.maximumBytes = maximumBytes; self.maximumCount = maximumCount
    }
    public func url(for observationID: UUID) -> URL {
        directory.appendingPathComponent(observationID.uuidString).appendingPathExtension("jpg")
    }
    public func contains(_ observationID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: observationID).path)
    }
    /// Writes one private image, then prunes ordinary images before learned examples.
    public func save(_ jpeg: Data, for observationID: UUID, learned: Set<UUID> = []) throws {
        guard !jpeg.isEmpty, jpeg.count <= maximumBytes, maximumCount > 0 else { throw Failure.invalidImage }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let destination = url(for: observationID)
        try jpeg.write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try prune(learned: learned, keeping: observationID)
    }
    public func prune(learned: Set<UUID>, keeping: UUID? = nil) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        let records = files.compactMap { file -> (url: URL, id: UUID, bytes: Int, date: Date)? in
            guard file.pathExtension == "jpg", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (file, id, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var bytes = records.reduce(0) { $0 + $1.bytes }; var count = records.count
        let ordered = records.filter { $0.id != keeping }.sorted {
            let a = learned.contains($0.id), b = learned.contains($1.id)
            return a != b ? !a : $0.date < $1.date
        }
        for item in ordered where bytes > maximumBytes || count > maximumCount {
            // Another writer may already have removed it; only count files this call removed.
            guard (try? fm.removeItem(at: item.url)) != nil else { continue }
            bytes -= item.bytes; count -= 1
        }
    }
}
