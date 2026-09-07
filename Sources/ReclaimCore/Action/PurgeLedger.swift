import Foundation

public struct PurgeLedgerEntry: Codable, Identifiable, Sendable {
    public let id: String
    public let date: Date
    public let succeeded: [String]
    public let failed: [String]
    public let deletedBytes: Int64
    public let freeBeforeBytes: Int64
    public let freeAfterBytes: Int64
    /// A measured volume delta, only attributed to a purge with a successful deletion.
    /// Snapshot-pinned bytes remain zero until the OS actually releases them.
    public var verifiedFreedBytes: Int64 { succeeded.isEmpty ? 0 : max(0, freeAfterBytes - freeBeforeBytes) }
    public init(id: String = UUID().uuidString, date: Date = Date(), succeeded: [String], failed: [String],
                deletedBytes: Int64, freeBeforeBytes: Int64, freeAfterBytes: Int64) {
        self.id = id; self.date = date; self.succeeded = succeeded; self.failed = failed
        self.deletedBytes = deletedBytes; self.freeBeforeBytes = freeBeforeBytes; self.freeAfterBytes = freeAfterBytes
    }
}

public struct PurgeLedgerStore: Sendable {
    public let url: URL
    public init(home: String = NSHomeDirectory()) {
        url = URL(fileURLWithPath: home).appendingPathComponent(".reclaim/purges.json")
    }
    public func all() throws -> [PurgeLedgerEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PurgeLedgerEntry].self, from: Data(contentsOf: url))
    }
    public func append(_ entry: PurgeLedgerEntry) throws {
        var entries = try all(); entries.append(entry)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}

public enum PurgeExecutor {
    public static func run(ids: [String], home: String = NSHomeDirectory()) -> PurgeLedgerEntry {
        let before = VolumeProbe.dataVolume().free
        var succeeded: [String] = [], failed: [String] = []
        var deletedBytes: Int64 = 0
        for id in Set(ids).sorted() {
            let quarantine = Quarantine(home: home, sessionID: id)
            do {
                let entries = try quarantine.manifest()
                // Restored items no longer in the vault do not count as deleted.
                let remaining = entries.filter { FileManager.default.fileExists(atPath: $0.quarantinePath) }
                try quarantine.purge()
                succeeded.append(id)
                deletedBytes += remaining.reduce(0) { $0 + $1.bytes }
            } catch { failed.append(id) }
        }
        return PurgeLedgerEntry(succeeded: succeeded, failed: failed, deletedBytes: deletedBytes,
                                freeBeforeBytes: before, freeAfterBytes: VolumeProbe.dataVolume().free)
    }
}
