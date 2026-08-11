import Foundation

/// The judgment layer: finds personal files the user probably doesn't want,
/// and says WHY in plain language. This is advisory intelligence — everything
/// it surfaces is personal content (Orange/Blue), never auto-deleted.
///
/// Design stance: be genuinely helpful, never presumptuous. A suggestion is
/// "hey, we think you might not need this," backed by concrete evidence
/// (size, age, a duplicate twin) — the opposite of a black-box cleaner.
public struct JudgmentScanner: Sendable {

    public struct Config: Sendable {
        /// Files at/above this size are worth a look regardless.
        public var veryLargeBytes: Int64 = 1024 * 1024 * 1024        // 1 GB
        /// "Large" threshold for the old-and-large heuristic.
        public var largeBytes: Int64 = 200 * 1024 * 1024             // 200 MB
        /// Untouched this long counts as "old".
        public var oldInterval: TimeInterval = 180 * 86400          // ~6 months
        /// Minimum size for an individual-file suggestion.
        public var minBytes: Int64 = 100 * 1024 * 1024              // 100 MB
        /// Per-file floor for counting toward a cluster.
        public var clusterFileFloor: Int64 = 2 * 1024 * 1024        // 2 MB
        /// A cluster is reported when its total reaches this…
        public var clusterMinTotal: Int64 = 300 * 1024 * 1024       // 300 MB
        /// …and it holds at least this many files.
        public var clusterMinCount: Int = 4
        /// Directories to search for personal files (under home).
        public var searchDirs = [
            "Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures",
        ]
        public init() {}
    }

    public var config: Config
    public var inventory: AppInventory

    public init(config: Config = Config(), inventory: AppInventory? = nil) {
        self.config = config
        self.inventory = inventory ?? AppInventory.build()
    }

    public func scan(homeOverride: String? = nil,
                     now: Date = Date()) -> JudgmentReport {
        let start = now
        let home = homeOverride ?? NSHomeDirectory()
        var suggestions: [Suggestion] = []
        var bySize: [Int64: [FileFacts]] = [:]   // for duplicate detection
        // (dir, category) → files, for accumulation/cluster detection.
        var clusterBuckets: [String: [FileFacts]] = [:]

        for dir in config.searchDirs {
            let root = (home as NSString).appendingPathComponent(dir)
            for facts in files(under: root) {
                // Duplicate candidates: any file above the cluster floor.
                if facts.size >= config.clusterFileFloor {
                    bySize[facts.size, default: []].append(facts)
                    let cat = FileCategory.of(facts.path)
                    clusterBuckets["\(dir)|\(cat.rawValue)", default: []].append(facts)
                }
                // Individual suggestions only for notable files.
                if facts.size >= config.minBytes, let s = judge(facts, dir: dir, now: now) {
                    suggestions.append(s)
                }
            }
        }

        // iOS device backups: age-flag each device backup folder.
        suggestions.append(contentsOf: deviceBackups(home: home, now: now))

        // Duplicate detection: files sharing an exact size are candidates;
        // confirm with a content hash before claiming they're duplicates.
        suggestions.append(contentsOf: duplicates(bySize))

        let clusters = buildClusters(clusterBuckets, now: now)

        // De-dup suggestions by path, keeping the highest-confidence reason.
        var best: [String: Suggestion] = [:]
        for s in suggestions {
            if let existing = best[s.path], existing.confidence >= s.confidence { continue }
            best[s.path] = s
        }
        let final = best.values.sorted { $0.sizeBytes > $1.sizeBytes }
        return JudgmentReport(scannedAt: start, suggestions: final,
                              clusters: clusters,
                              elapsedSeconds: now.timeIntervalSince(start))
    }

    // MARK: - Clusters

    private func buildClusters(_ buckets: [String: [FileFacts]], now: Date) -> [Cluster] {
        var out: [Cluster] = []
        for (key, files) in buckets {
            let total = files.reduce(0) { $0 + $1.size }
            guard files.count >= config.clusterMinCount, total >= config.clusterMinTotal else { continue }
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let dir = parts[0]
            let category = FileCategory(rawValue: parts.count > 1 ? parts[1] : "") ?? .other
            guard category != .other else { continue }   // don't cluster the junk drawer

            let dates = files.compactMap(\.lastModified).sorted()
            let oldest = dates.first, newest = dates.last
            let oldestDays = oldest.map { Int(now.timeIntervalSince($0) / 86400) }
            let entries = files.sorted { $0.size > $1.size }
                .map { ClusterFile(path: $0.path, bytes: $0.size, modified: $0.lastModified) }

            out.append(Cluster(
                directory: dir, category: category.plural, count: files.count,
                totalBytes: total, oldest: oldest, newest: newest,
                rationale: "\(files.count) \(category.plural.lowercased()) in \(dir) totaling \(ByteFormatter.string(total))\(oldestDays.map { ", oldest from \($0) days ago" } ?? ""). \(category.hint)",
                riskTier: category.riskTier, files: entries))
        }
        return out.sorted { $0.totalBytes > $1.totalBytes }
    }

    // MARK: - Per-file judgment

    private func judge(_ f: FileFacts, dir: String, now: Date) -> Suggestion? {
        let name = (f.path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let ageDays = f.lastModified.map { Int(now.timeIntervalSince($0) / 86400) }
        let isOld = f.lastModified.map { now.timeIntervalSince($0) >= config.oldInterval } ?? false

        // Screen recordings — big, rarely rewatched.
        if name.hasPrefix("Screen Recording") || (ext == "mov" && name.lowercased().contains("screen")) {
            return Suggestion(
                path: f.path, sizeBytes: f.size, reason: .oldScreenRecording,
                rationale: "Screen recording (\(ByteFormatter.string(f.size)))\(ageDays.map { ", from \($0) days ago" } ?? ""). Screen recordings are big and usually watched once — worth a look.",
                lastModified: f.lastModified, lastAccessed: f.lastAccessed,
                confidence: isOld ? 0.8 : 0.6, riskTier: .orange)
        }

        // Screenshots piling up on the Desktop.
        if (name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot")) && (ext == "png" || ext == "jpg") {
            return Suggestion(
                path: f.path, sizeBytes: f.size, reason: .oldScreenshot,
                rationale: "Screenshot\(ageDays.map { " from \($0) days ago" } ?? ""). Old screenshots rarely get reused.",
                lastModified: f.lastModified, lastAccessed: f.lastAccessed,
                confidence: isOld ? 0.7 : 0.45, riskTier: .orange)
        }

        // Installers for apps that are already installed.
        if ext == "dmg" || ext == "pkg" {
            let appName = installerAppName(name)
            if let appName, inventory.names.contains(appName.lowercased()) {
                return Suggestion(
                    path: f.path, sizeBytes: f.size, reason: .installerForInstalledApp,
                    rationale: "Installer for “\(appName)”, which is already installed. Keeping the installer is redundant unless you reinstall often.",
                    lastModified: f.lastModified, lastAccessed: f.lastAccessed,
                    confidence: 0.85, riskTier: .blue)
            }
            if isOld {
                return Suggestion(
                    path: f.path, sizeBytes: f.size, reason: .oldDownload,
                    rationale: "Installer downloaded \(ageDays ?? 0) days ago and untouched since. Most installers are one-time use.",
                    lastModified: f.lastModified, lastAccessed: f.lastAccessed,
                    confidence: 0.65, riskTier: .blue)
            }
        }

        // Old downloads in general.
        if dir == "Downloads", isOld, f.size >= config.largeBytes {
            return Suggestion(
                path: f.path, sizeBytes: f.size, reason: .oldDownload,
                rationale: "In Downloads, \(ByteFormatter.string(f.size)), untouched for \(ageDays ?? 0) days. Downloads are usually transient.",
                lastModified: f.lastModified, lastAccessed: f.lastAccessed,
                confidence: 0.55, riskTier: .orange)
        }

        // Old and large anywhere.
        if isOld, f.size >= config.largeBytes {
            return Suggestion(
                path: f.path, sizeBytes: f.size, reason: .oldAndLarge,
                rationale: "\(ByteFormatter.string(f.size)), not modified in \(ageDays ?? 0) days. Large files you haven't touched in a while are prime space to reclaim.",
                lastModified: f.lastModified, lastAccessed: f.lastAccessed,
                confidence: 0.5, riskTier: .orange)
        }

        // Very large regardless of age — just surface for awareness.
        if f.size >= config.veryLargeBytes {
            return Suggestion(
                path: f.path, sizeBytes: f.size, reason: .veryLarge,
                rationale: "One of your largest files (\(ByteFormatter.string(f.size))). Worth confirming you still need it here.",
                lastModified: f.lastModified, lastAccessed: f.lastAccessed,
                confidence: 0.35, riskTier: .orange)
        }
        return nil
    }

    // MARK: - Duplicates

    private func duplicates(_ bySize: [Int64: [FileFacts]]) -> [Suggestion] {
        var out: [Suggestion] = []
        for (size, group) in bySize where group.count > 1 {
            // Never dedup cloud-synced files — a local delete can propagate to
            // iCloud/Dropbox and other devices.
            let candidates = group.filter { !FileIdentity.isCloudSynced($0.path) }
            guard candidates.count > 1 else { continue }

            // Same-size candidates — bucket by a cheap sampled hash first.
            var bySample: [String: [FileFacts]] = [:]
            for f in candidates {
                if let h = QuickHash.hash(path: f.path) { bySample[h, default: []].append(f) }
            }
            for (sampleKey, sampled) in bySample where sampled.count > 1 {
                // Confirm true identity for large files — a head/tail match is
                // not proof, so we never claim "exact duplicate" without it.
                let confirmed: [String: [FileFacts]]
                if size <= QuickHash.fullHashLimit {
                    confirmed = [sampleKey: sampled]
                } else {
                    var byFull: [String: [FileFacts]] = [:]
                    for f in sampled {
                        if let h = QuickHash.fullHash(path: f.path) { byFull[h, default: []].append(f) }
                    }
                    confirmed = byFull
                }
                for (_, exact) in confirmed where exact.count > 1 {
                    // Collapse hardlinks — removing another name for one inode
                    // frees nothing, so it isn't a reclaimable duplicate.
                    var byInode: [String: FileFacts] = [:]
                    var noKey: [FileFacts] = []
                    for f in exact {
                        if let k = FileIdentity.inodeKey(f.path) {
                            if byInode[k] == nil { byInode[k] = f }
                        } else { noKey.append(f) }
                    }
                    let distinct = Array(byInode.values) + noKey
                    guard distinct.count > 1 else { continue }
                    // Keep the NEWEST copy — unified with DuplicateFinder so the
                    // two engines never disagree on which file to keep.
                    let sorted = distinct.sorted {
                        ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast)
                    }
                    let keep = sorted[0]
                    for dup in sorted.dropFirst() {
                        out.append(Suggestion(
                            path: dup.path, sizeBytes: dup.size, reason: .duplicate,
                            rationale: "Exact duplicate of “\((keep.path as NSString).lastPathComponent)” — identical content, \(ByteFormatter.string(dup.size)). Reclaim keeps the newest copy; removing this one is reversible.",
                            lastModified: dup.lastModified, lastAccessed: dup.lastAccessed,
                            confidence: 0.9, riskTier: .blue, duplicateOf: keep.path))
                    }
                }
            }
        }
        return out
    }

    // MARK: - iOS device backups

    private func deviceBackups(home: String, now: Date) -> [Suggestion] {
        let base = (home as NSString).appendingPathComponent("Library/Application Support/MobileSync/Backup")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        var out: [Suggestion] = []
        for entry in entries where !entry.hasPrefix(".") {
            let path = (base as NSString).appendingPathComponent(entry)
            let m = SizeMeasurement.measure(path)
            guard m.allocatedBytes >= config.minBytes else { continue }
            let ageDays = m.lastModified.map { Int(now.timeIntervalSince($0) / 86400) }
            let stale = m.lastModified.map { now.timeIntervalSince($0) >= 365 * 86400 } ?? false
            out.append(Suggestion(
                path: path, sizeBytes: m.allocatedBytes, reason: .oldDeviceBackup,
                rationale: "Local iPhone/iPad backup (\(ByteFormatter.string(m.allocatedBytes)))\(ageDays.map { ", last updated \($0) days ago" } ?? ""). If this is a device you no longer own or that backs up to iCloud, it may be safe to remove — but a backup can be the only copy of a lost device's data. Review carefully.",
                lastModified: m.lastModified, lastAccessed: nil,
                confidence: stale ? 0.6 : 0.3, riskTier: .orange))
        }
        return out
    }

    // MARK: - File enumeration

    struct FileFacts {
        let path: String
        let size: Int64
        let lastModified: Date?
        let lastAccessed: Date?
    }

    private func files(under root: String) -> [FileFacts] {
        let url = URL(fileURLWithPath: root)
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey,
            .contentModificationDateKey, .contentAccessDateKey,
        ]
        // Don't descend into app/library bundles — treat them as opaque.
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true })
        var out: [FileFacts] = []
        while let item = enumerator?.nextObject() as? URL {
            guard let v = try? item.resourceValues(forKeys: keys),
                  v.isRegularFile == true else { continue }
            out.append(FileFacts(
                path: item.path,
                size: Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0),
                lastModified: v.contentModificationDate,
                lastAccessed: v.contentAccessDate))
        }
        return out
    }

    /// Best-effort app name from an installer filename ("Zoom-6.1.dmg" → "Zoom").
    private func installerAppName(_ filename: String) -> String? {
        let base = (filename as NSString).deletingPathExtension
        // Cut at first separator followed by a version-ish token.
        let stopped = base.replacingOccurrences(of: "_", with: "-")
        let head = stopped.split(separator: "-").first.map(String.init) ?? base
        return head.isEmpty ? nil : head
    }
}
