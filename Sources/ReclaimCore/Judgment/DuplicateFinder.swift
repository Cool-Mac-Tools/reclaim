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
        // Never dedup cloud-synced files — deleting a local copy can remove it
        // from iCloud/Dropbox and every other device.
        let candidates = files.filter { !FileIdentity.isCloudSynced($0.path) }

        // Stage 1: bucket by exact byte size. Non-colliding sizes can't be dupes.
        var bySize: [Int64: [ClusterFile]] = [:]
        for f in candidates where f.bytes > 0 { bySize[f.bytes, default: []].append(f) }

        var groups: [DuplicateGroup] = []
        for (size, sized) in bySize where sized.count >= 2 {
            // Stage 2: cheap sampled hash (head+tail+size) to bucket likely matches.
            var bySample: [String: [ClusterFile]] = [:]
            for f in sized {
                guard let h = QuickHash.hash(path: f.path) else { continue }
                bySample[h, default: []].append(f)
            }
            for (sampleKey, sampled) in bySample where sampled.count >= 2 {
                // Stage 3: CONFIRM true identity. Small files were fully hashed
                // already; larger files get a full-content hash so we never call
                // a head/tail match an "exact duplicate".
                let confirmed: [String: [ClusterFile]]
                if size <= QuickHash.fullHashLimit {
                    confirmed = [sampleKey: sampled]
                } else {
                    var byFull: [String: [ClusterFile]] = [:]
                    for f in sampled {
                        guard let h = QuickHash.fullHash(path: f.path) else { continue }
                        byFull[h, default: []].append(f)
                    }
                    confirmed = byFull
                }
                for (key, exact) in confirmed where exact.count >= 2 {
                    let distinct = Self.collapseHardlinks(exact)
                    guard distinct.count >= 2 else { continue }
                    let newestFirst = distinct.sorted {
                        ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast)
                    }
                    groups.append(DuplicateGroup(hash: key, bytes: size, files: newestFirst))
                }
            }
        }
        // Biggest wins first.
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Keep one file per (device, inode). Hardlinks are multiple names for the
    /// same bytes — removing an "extra" frees nothing, so they must not be
    /// counted as reclaimable duplicates.
    static func collapseHardlinks(_ files: [ClusterFile]) -> [ClusterFile] {
        var byInode: [String: ClusterFile] = [:]
        var noKey: [ClusterFile] = []
        for f in files {
            if let k = FileIdentity.inodeKey(f.path) {
                if byInode[k] == nil { byInode[k] = f }
            } else {
                noKey.append(f)
            }
        }
        return Array(byInode.values) + noKey
    }
}
