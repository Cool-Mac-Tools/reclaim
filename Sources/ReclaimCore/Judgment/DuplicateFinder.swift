import Foundation

/// A set of byte-identical files. Reclaiming a group means keeping one copy
/// (the newest) and removing the rest.
public struct DuplicateGroup: Codable, Sendable, Identifiable {
    public var id: String { hash }
    public let hash: String
    public let bytes: Int64            // size of a single copy
    public let files: [ClusterFile]    // all copies, newest first

    public init(hash: String, bytes: Int64, files: [ClusterFile]) {
        self.hash = hash
        self.bytes = bytes
        self.files = files
    }

    public var count: Int { files.count }
    /// Space freed by keeping exactly one copy.
    public var reclaimableBytes: Int64 { bytes * Int64(max(0, files.count - 1)) }
    /// The copy we'd keep by default: the most recently modified.
    public var keeper: ClusterFile? { files.first }
    /// The copies we'd remove by default (everything but the keeper).
    public var extras: [ClusterFile] { Array(files.dropFirst()) }
}

/// Finds byte-identical files across a candidate set. Two-stage to stay fast:
/// group by exact size first (free), then confirm collisions with a sampled
/// content hash (QuickHash). Read-only — it only reads to fingerprint.
public enum DuplicateFinder {
    public static func find(in files: [ClusterFile]) -> [DuplicateGroup] {
        // Stage 1: bucket by exact byte size. Non-colliding sizes can't be dupes.
        var bySize: [Int64: [ClusterFile]] = [:]
        for f in files where f.bytes > 0 { bySize[f.bytes, default: []].append(f) }

        var groups: [DuplicateGroup] = []
        for (size, candidates) in bySize where candidates.count >= 2 {
            // Stage 2: confirm with a content hash.
            var byHash: [String: [ClusterFile]] = [:]
            for f in candidates {
                guard let h = QuickHash.hash(path: f.path) else { continue }
                byHash[h, default: []].append(f)
            }
            for (hash, dups) in byHash where dups.count >= 2 {
                let newestFirst = dups.sorted {
                    ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast)
                }
                groups.append(DuplicateGroup(hash: hash, bytes: size, files: newestFirst))
            }
        }
        // Biggest wins first.
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }
}
