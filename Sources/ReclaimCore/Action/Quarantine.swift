import Foundation

/// A single quarantined item — enough to restore it exactly.
public struct QuarantineEntry: Codable, Sendable {
    public let originalPath: String
    public let quarantinePath: String
    public let bytes: Int64
    public let quarantinedAt: Date
    public let source: String            // recipe id, "orphan", "review", …

    public init(originalPath: String, quarantinePath: String, bytes: Int64,
                quarantinedAt: Date, source: String) {
        self.originalPath = originalPath
        self.quarantinePath = quarantinePath
        self.bytes = bytes
        self.quarantinedAt = quarantinedAt
        self.source = source
    }
}

/// The Reclaim quarantine vault. Reversible by default: items are MOVED here
/// (not deleted) so any action can be undone within the retention window.
/// Permanent deletion is a separate, explicit step (`purge`).
///
/// Layout: ~/.reclaim/quarantine/<sessionID>/<mirrored original path>
/// A manifest.json per session records every entry for exact restore.
public struct Quarantine: Sendable {
    public let root: String
    public let sessionID: String

    public init(home: String = NSHomeDirectory(), sessionID: String) {
        self.root = (home as NSString).appendingPathComponent(".reclaim/quarantine")
        self.sessionID = sessionID
    }

    var sessionDir: String { (root as NSString).appendingPathComponent(sessionID) }
    var manifestPath: String { (sessionDir as NSString).appendingPathComponent("manifest.json") }

    /// Move a path into quarantine, mirroring its original location so two
    /// files with the same basename never collide. Returns the entry, or
    /// throws if the source is missing or the move fails.
    public func store(_ originalPath: String, source: String, now: Date = Date()) throws -> QuarantineEntry {
        let fm = FileManager.default
        guard fm.fileExists(atPath: originalPath) else {
            throw QuarantineError.sourceMissing(originalPath)
        }
        let bytes = SizeMeasurement.measure(originalPath).allocatedBytes

        // Mirror the absolute path under the session dir (strip leading "/").
        let relative = originalPath.hasPrefix("/") ? String(originalPath.dropFirst()) : originalPath
        let dest = (sessionDir as NSString).appendingPathComponent(relative)
        let destParent = (dest as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: destParent, withIntermediateDirectories: true)

        // Refuse to clobber an existing quarantine entry.
        guard !fm.fileExists(atPath: dest) else {
            throw QuarantineError.destinationExists(dest)
        }
        try fm.moveItem(atPath: originalPath, toPath: dest)

        let entry = QuarantineEntry(
            originalPath: originalPath, quarantinePath: dest, bytes: bytes,
            quarantinedAt: now, source: source)
        try appendManifest(entry)
        return entry
    }

    /// Move the CONTENTS of a directory into quarantine, leaving the (often
    /// protected) container in place. macOS blocks moving/removing top-level
    /// ~/Library folders even for their owner, but modifying files *inside*
    /// them is allowed — so this is how we reclaim caches/logs/etc. that live
    /// in protected containers. Returns what moved and what couldn't.
    public func storeContents(_ dir: String, source: String, now: Date = Date())
        -> (bytes: Int64, count: Int, failed: Int) {
        let fm = FileManager.default
        var bytes: Int64 = 0, count = 0, failed = 0
        let children = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        for child in children {
            let childPath = (dir as NSString).appendingPathComponent(child)
            do {
                let entry = try store(childPath, source: source, now: now)
                bytes += entry.bytes; count += 1
            } catch {
                failed += 1
            }
        }
        return (bytes, count, failed)
    }

    /// Restore every entry in this session to its original location.
    /// Returns (restored, failed) path lists.
    @discardableResult
    public func restoreAll() throws -> (restored: [String], failed: [String]) {
        let fm = FileManager.default
        var restored: [String] = [], failed: [String] = []
        for entry in try manifest() {
            let parent = (entry.originalPath as NSString).deletingLastPathComponent
            do {
                guard fm.fileExists(atPath: entry.quarantinePath) else {
                    failed.append(entry.originalPath); continue
                }
                // Don't overwrite something the user recreated at the origin.
                if fm.fileExists(atPath: entry.originalPath) {
                    failed.append(entry.originalPath); continue
                }
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: entry.quarantinePath, toPath: entry.originalPath)
                restored.append(entry.originalPath)
            } catch {
                failed.append(entry.originalPath)
            }
        }
        return (restored, failed)
    }

    /// Permanently delete this quarantine session. Irreversible — callers must
    /// confirm explicitly before invoking.
    public func purge() throws {
        try FileManager.default.removeItem(atPath: sessionDir)
    }

    public func manifest() throws -> [QuarantineEntry] {
        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([QuarantineEntry].self, from: data)
    }

    private func appendManifest(_ entry: QuarantineEntry) throws {
        var entries = (try? manifest()) ?? []
        entries.append(entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        try encoder.encode(entries).write(to: URL(fileURLWithPath: manifestPath))
    }

    /// All quarantine session IDs on disk, newest-looking first.
    public static func sessions(home: String = NSHomeDirectory()) -> [String] {
        let root = (home as NSString).appendingPathComponent(".reclaim/quarantine")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return entries.filter { !$0.hasPrefix(".") }.sorted(by: >)
    }
}

public enum QuarantineError: Error, CustomStringConvertible {
    case sourceMissing(String)
    case destinationExists(String)

    public var description: String {
        switch self {
        case .sourceMissing(let p): "source no longer exists: \(p)"
        case .destinationExists(let p): "already in quarantine: \(p)"
        }
    }
}
