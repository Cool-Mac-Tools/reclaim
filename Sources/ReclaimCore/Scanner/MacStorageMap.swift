import Foundation

/// One user-facing slice of what's using the disk. Bytes are physical
/// (allocated) size, matching how the volume actually accounts for space.
public struct StorageCategory: Codable, Sendable, Identifiable {
    public var id: String { key }
    public let key: String          // stable id, e.g. "applications"
    public let name: String         // "Applications"
    public let bytes: Int64
    public let fileCount: Int
    public let symbol: String       // SF Symbol
    public let detail: String       // plain-language description
    /// False for the reconciling "System & other" remainder — it's computed
    /// from the disk total, not walked file-by-file.
    public let itemized: Bool

    public init(key: String, name: String, bytes: Int64, fileCount: Int,
                symbol: String, detail: String, itemized: Bool) {
        self.key = key
        self.name = name
        self.bytes = bytes
        self.fileCount = fileCount
        self.symbol = symbol
        self.detail = detail
        self.itemized = itemized
    }
}

/// The output of a "My Mac" scan: an honest, whole-disk picture of where the
/// space goes. Unlike the recipe scan (what's *removable*), this shows
/// *everything* — and is anchored to the volume's real used bytes.
public struct MacStorageReport: Codable, Sendable {
    public let scannedAt: Date
    public let hostname: String
    /// Volume capacity — the "of Y" in "X available of Y".
    public let capacityBytes: Int64
    /// Space the OS reports as available (matches Finder / About This Mac).
    public let freeBytes: Int64
    /// capacity − free. The number every category is reconciled against.
    public let usedBytes: Int64
    /// Occupied-but-reclaimable space (caches/snapshots the OS can evict).
    public let purgeableBytes: Int64
    /// Categories, largest first. Always includes a "System & other" remainder
    /// so the itemized slices + remainder sum EXACTLY to usedBytes.
    public let categories: [StorageCategory]
    /// Sum of the walked (itemized) categories — what Reclaim could actually see.
    public let measuredBytes: Int64
    /// True in the rare case our walk measured more than the disk reports used
    /// (APFS clones / hardlinks counted under multiple folders). Then there is
    /// no remainder and the picture is approximate — surfaced honestly.
    public let overMeasured: Bool
    public let totalFileCount: Int
    public let snapshots: SnapshotStatus
    /// Whether Reclaim could see TCC-protected data during the walk. When
    /// denied, protected files are silently skipped and land in the unitemized
    /// remainder — so the map under-itemizes until FDA is granted.
    public let fullDiskAccess: FullDiskAccess.Status
    /// The largest files in each category (keyed by category id), so My Mac can
    /// drill in, filter, and let the user bulk-select. Capped per category and
    /// floored at a minimum size — the long tail of tiny files isn't
    /// individually reclaimable and would bloat the catalog.
    public let filesByCategory: [String: [ClusterFile]]
    /// Byte-identical file groups found across the catalog — keep one, reclaim
    /// the rest. Largest reclaimable first.
    public let duplicates: [DuplicateGroup]
    public let elapsedSeconds: Double

    /// Total space recoverable by de-duplicating (keeping one copy per group).
    public var duplicateReclaimableBytes: Int64 {
        duplicates.reduce(0) { $0 + $1.reclaimableBytes }
    }

    public var usedFraction: Double {
        capacityBytes > 0 ? Double(usedBytes) / Double(capacityBytes) : 0
    }

    public init(scannedAt: Date, hostname: String, capacityBytes: Int64,
                freeBytes: Int64, usedBytes: Int64, purgeableBytes: Int64,
                categories: [StorageCategory], measuredBytes: Int64,
                overMeasured: Bool, totalFileCount: Int,
                snapshots: SnapshotStatus,
                fullDiskAccess: FullDiskAccess.Status,
                filesByCategory: [String: [ClusterFile]] = [:],
                duplicates: [DuplicateGroup] = [],
                elapsedSeconds: Double) {
        self.scannedAt = scannedAt
        self.hostname = hostname
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
        self.usedBytes = usedBytes
        self.purgeableBytes = purgeableBytes
        self.categories = categories
        self.measuredBytes = measuredBytes
        self.overMeasured = overMeasured
        self.totalFileCount = totalFileCount
        self.snapshots = snapshots
        self.fullDiskAccess = fullDiskAccess
        self.filesByCategory = filesByCategory
        self.duplicates = duplicates
        self.elapsedSeconds = elapsedSeconds
    }
}

/// Builds the "My Mac" storage map: a whole-disk breakdown that always
/// reconciles to the volume's real used space.
///
/// Accuracy contract: the ONE number we can state with certainty is the
/// volume's used bytes (capacity − free). We walk the entire data volume,
/// classify each readable file into a familiar category, then compute the gap
/// `used − measured` as a single honest "macOS System & Snapshots" slice
/// (the sealed system volume, snapshots, and anything permissions blocked).
/// So the categories always add up to the disk's actual usage — never a
/// fabricated total. Read-only, always.
public struct MacStorageMap: Sendable {
    public let home: String
    /// Test seams: when nil, the real volume / data-volume root is used.
    let scanRootOverride: String?
    let capacityOverride: Int64?
    let freeOverride: Int64?
    let rawFreeOverride: Int64?

    public init(home: String = NSHomeDirectory()) {
        self.init(home: home, scanRootOverride: nil,
                  capacityOverride: nil, freeOverride: nil, rawFreeOverride: nil)
    }

    init(home: String, scanRootOverride: String?,
         capacityOverride: Int64?, freeOverride: Int64?, rawFreeOverride: Int64?) {
        self.home = home
        self.scanRootOverride = scanRootOverride
        self.capacityOverride = capacityOverride
        self.freeOverride = freeOverride
        self.rawFreeOverride = rawFreeOverride
    }

    /// The root to enumerate: the writable data volume, which holds all user
    /// and system-app data (/Users, /Library, /Applications, Homebrew,
    /// /private/var all firmlink here). The only thing it excludes is the
    /// sealed read-only system volume — which is exactly what the remainder
    /// accounts for. Falls back to `/` on pre-split macOS.
    func scanRoot() -> String {
        if let override = scanRootOverride { return override }
        return FileManager.default.fileExists(atPath: "/System/Volumes/Data")
            ? "/System/Volumes/Data" : "/"
    }

    // MARK: - Category taxonomy

    struct CategorySpec { let key, name, symbol, detail: String }

    /// Display metadata, keyed by the id `classify` returns. Order here is the
    /// tiebreak when two categories are the same size; real order is by bytes.
    static let specs: [CategorySpec] = [
        .init(key: "applications", name: "Applications", symbol: "app.badge",
              detail: "Apps installed in your Applications folders."),
        .init(key: "photos", name: "Photos & Images", symbol: "photo.on.rectangle",
              detail: "Your Pictures folder, including Photos libraries."),
        .init(key: "movies", name: "Movies & Video", symbol: "film",
              detail: "Your Movies folder and video files."),
        .init(key: "music", name: "Music & Audio", symbol: "music.note",
              detail: "Your Music folder and audio libraries."),
        .init(key: "documents", name: "Documents & Desktop", symbol: "doc.text",
              detail: "Files on your Desktop and in Documents."),
        .init(key: "downloads", name: "Downloads", symbol: "arrow.down.circle",
              detail: "Everything in your Downloads folder."),
        .init(key: "developer", name: "Developer & Caches", symbol: "hammer",
              detail: "Xcode data, build output, and package-manager caches."),
        .init(key: "mail", name: "Mail", symbol: "envelope",
              detail: "Locally stored mail and attachments."),
        .init(key: "messages", name: "Messages", symbol: "message",
              detail: "Messages history and attachments."),
        .init(key: "appdata", name: "App Data & Support", symbol: "shippingbox",
              detail: "App containers, Application Support, and preferences."),
        .init(key: "trash", name: "Trash", symbol: "trash",
              detail: "Items in the Trash — still using space until emptied."),
        .init(key: "userother", name: "Other User Files", symbol: "folder",
              detail: "Other files in your home folder."),
        .init(key: "systemdata", name: "System Files", symbol: "gearshape.2",
              detail: "System-level app support, caches, logs, virtual-memory swap, "
                    + "and shared data outside your home folder."),
        .init(key: "otherusers", name: "Other Users", symbol: "person.2",
              detail: "Files belonging to other user accounts and the shared folder."),
        // ── Remainder, itemized into its real parts ──────────────────
        .init(key: "protected", name: "Protected Data", symbol: "lock.doc",
              detail: "Data on your disk Reclaim can't read yet — Messages, Mail, and "
                    + "app containers. Grant Full Disk Access to itemize and clean it."),
        .init(key: "macos", name: "macOS System", symbol: "apple.logo",
              detail: "The sealed macOS system volume. Read-only and protected — never "
                    + "removable, and not counted against your personal space."),
        .init(key: "preboot", name: "System Update Files", symbol: "arrow.triangle.2.circlepath",
              detail: "The Preboot/Update volumes macOS uses to install updates. Shrinks "
                    + "on its own after an update settles."),
        .init(key: "vmswap", name: "Virtual Memory", symbol: "memorychip",
              detail: "Swap and sleep-image files macOS manages automatically. Not safe "
                    + "to remove by hand — the system reclaims it as needed."),
        .init(key: "snapshots", name: "Snapshots & Other", symbol: "clock.arrow.circlepath",
              detail: "Time Machine local snapshots pinning changed blocks, plus anything "
                    + "left unaccounted. Snapshots expire on their own within ~24h."),
        .init(key: "system", name: "macOS System & Snapshots", symbol: "gearshape",
              detail: "The sealed macOS system volume, virtual-memory swap, and Time "
                    + "Machine snapshots — plus any files permissions blocked. Mostly "
                    + "space no app can safely reclaim. Computed so the total matches "
                    + "your disk exactly."),
    ]

    static func spec(_ key: String) -> CategorySpec {
        specs.first { $0.key == key } ?? specs.last!
    }

    /// Hidden home directories that are really developer caches, not documents.
    static let devDotDirs = [".npm", ".cache", ".gradle", ".docker", ".m2",
                             ".cargo", ".rustup", ".yarn", ".gem", ".cocoapods",
                             ".pnpm-store", ".bun", ".deno", ".nuget", ".colima",
                             ".orbstack", ".lima"]

    /// Maps an absolute path to a category key. Handles files in the user's
    /// home *and* elsewhere on the data volume (/Library, Homebrew,
    /// /private/var, other users). Pure and order-sensitive — most-specific
    /// rules win. Internal so it can be unit-tested.
    static func classify(_ rawPath: String, home rawHome: String) -> String {
        // Normalize prefixes so matching is stable: the data volume enumerates
        // as /System/Volumes/Data/… and firmlinked dirs surface as /private/…
        // — strip both to their familiar /Users, /Library form.
        func normalize(_ p: String) -> String {
            var s = p
            if s.hasPrefix("/System/Volumes/Data/") {
                s = String(s.dropFirst("/System/Volumes/Data".count))
            } else if s == "/System/Volumes/Data" {
                s = "/"
            }
            if s.hasPrefix("/private/") { s = String(s.dropFirst("/private".count)) }
            return s
        }
        let path = normalize(rawPath), home = normalize(rawHome)

        // ── Inside the user's home folder ──────────────────────────────
        if path == home || path.hasPrefix(home + "/") {
            func under(_ sub: String) -> Bool {
                let base = home + "/" + sub
                return path == base || path.hasPrefix(base + "/")
            }
            if under(".Trash") { return "trash" }
            if under("Library/Developer") || under("Library/Caches") { return "developer" }
            if under("Library/Mail") { return "mail" }
            if under("Library/Messages") { return "messages" }
            if under("Library") { return "appdata" }
            if under("Pictures") { return "photos" }
            if under("Movies") { return "movies" }
            if under("Music") { return "music" }
            if under("Documents") || under("Desktop") { return "documents" }
            if under("Downloads") { return "downloads" }
            for d in devDotDirs where under(d) { return "developer" }
            return "userother"
        }

        // ── Elsewhere on the data volume ───────────────────────────────
        func at(_ prefix: String) -> Bool { path == prefix || path.hasPrefix(prefix + "/") }
        if at("/Applications") { return "applications" }
        // Homebrew and other user-installed dev tooling.
        if at("/opt/homebrew") || at("/usr/local") || at("/opt") { return "developer" }
        // System-level app data, shared support, logs, VM swap, versions store.
        if at("/Library") || at("/usr") || at("/var") || at("/tmp")
            || at("/cores") || at("/.DocumentRevisions-V100") || at("/.Spotlight-V100") {
            return "systemdata"
        }
        if at("/Users") { return "otherusers" }  // /Users/Shared and other accounts
        return "systemdata"
    }

    // Catalog tuning: only files ≥ floor are individually browsable; keep the
    // largest N per category, trimming when the working list gets big.
    static let catalogFloorBytes: Int64 = 1024 * 1024        // 1 MB
    static let catalogKeepPerCategory = 1500
    static let catalogTrimAt = 4000

    /// Bundles treated as atomic: their internals must NEVER be listed as
    /// individually deletable. Removing a file inside a .photoslibrary or .app
    /// corrupts it (plan §02). Their bytes still count toward category totals.
    static let atomicBundleSuffixes = [
        ".photoslibrary", ".migratedphotolibrary", ".aplibrary",
        ".musiclibrary", ".tvlibrary", ".imovielibrary", ".fcpbundle",
        ".app", ".framework", ".bundle", ".plugin", ".photobooklibrary",
    ]

    /// True if the path lives inside one of the atomic bundles above.
    static func insideAtomicBundle(_ path: String) -> Bool {
        atomicBundleSuffixes.contains { path.contains($0 + "/") }
    }

    /// True if the path IS an atomic bundle (ends with one of the suffixes).
    public static func isAtomicBundle(_ path: String) -> Bool {
        atomicBundleSuffixes.contains { path.hasSuffix($0) }
    }

    /// The shallowest atomic-bundle ancestor of a path (the bundle itself if the
    /// path is one), else nil. Used to fold bundle contents into one entry.
    static func atomicBundleRoot(_ path: String) -> String? {
        var best: String?
        for suffix in atomicBundleSuffixes {
            var root: String?
            if let r = path.range(of: suffix + "/") {
                root = String(path[..<r.lowerBound]) + suffix
            } else if path.hasSuffix(suffix) {
                root = path
            }
            if let root, best == nil || root.count < best!.count { best = root }
        }
        return best
    }

    // MARK: - Run

    public func run(progress: (@Sendable (Int) -> Void)? = nil) -> MacStorageReport {
        let start = Date()
        let facts = volumeFacts()
        let used = max(0, facts.capacity - facts.importantFree)
        let purgeable = max(0, facts.importantFree - facts.rawFree)

        var bytesByKey: [String: Int64] = [:]
        var countByKey: [String: Int] = [:]
        var filesByKey: [String: [ClusterFile]] = [:]
        var bundleBytes: [String: Int64] = [:]   // atomic bundle → summed size
        var bundleKey: [String: String] = [:]     // atomic bundle → category
        var totalFiles = 0

        let sizeKeys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey,
            .contentModificationDateKey,
        ]

        // One pass over the entire data volume — every readable file is
        // classified by path, so out-of-home space (/Library, Homebrew,
        // /private/var, other users) is itemized instead of vanishing into the
        // remainder. Unreadable files (permissions / no FDA) are skipped and
        // fall into "macOS System & Snapshots".
        let root = scanRoot()
        let rootURL = URL(fileURLWithPath: root)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue {
            let enumerator = FileManager.default.enumerator(
                at: rootURL, includingPropertiesForKeys: Array(sizeKeys),
                options: [], errorHandler: { _, _ in true })  // skip unreadable, keep going
            while let item = enumerator?.nextObject() as? URL {
                guard let v = try? item.resourceValues(forKeys: sizeKeys),
                      v.isRegularFile == true else { continue }
                let bytes = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                let key = Self.classify(item.path, home: home)
                bytesByKey[key, default: 0] += bytes
                countByKey[key, default: 0] += 1
                totalFiles += 1
                if totalFiles % 100_000 == 0 { progress?(totalFiles) }

                // Catalog. Files inside an atomic bundle (.photoslibrary, .app…)
                // are summed into ONE bundle entry — never listed individually,
                // since deleting bundle internals corrupts them.
                if let bundle = Self.atomicBundleRoot(item.path) {
                    bundleBytes[bundle, default: 0] += bytes
                    if bundleKey[bundle] == nil { bundleKey[bundle] = Self.classify(bundle, home: home) }
                } else if bytes >= Self.catalogFloorBytes {
                    filesByKey[key, default: []].append(
                        ClusterFile(path: item.path, bytes: bytes, modified: v.contentModificationDate))
                    if filesByKey[key]!.count > Self.catalogTrimAt {
                        filesByKey[key] = Array(filesByKey[key]!
                            .sorted { $0.bytes > $1.bytes }.prefix(Self.catalogKeepPerCategory))
                    }
                }
            }
        }

        let measured = bytesByKey.values.reduce(0, +)
        let overMeasured = measured > used && used > 0

        // Fold each atomic bundle in as a single entry (whole Photos library,
        // each .app, etc.) so it's visible and openable but not piece-deletable.
        for (bpath, btot) in bundleBytes where btot >= Self.catalogFloorBytes {
            let key = bundleKey[bpath] ?? Self.classify(bpath, home: home)
            let mod = (try? FileManager.default.attributesOfItem(atPath: bpath)[.modificationDate]) as? Date
            filesByKey[key, default: []].append(ClusterFile(path: bpath, bytes: btot, modified: mod))
        }

        // Final catalog: largest-first, capped per category.
        let filesByCategory = filesByKey.mapValues {
            Array($0.sorted { $0.bytes > $1.bytes }.prefix(Self.catalogKeepPerCategory))
        }

        // Duplicate groups — restricted to personal-content categories. Dev
        // and system files (node binaries, toolchain libs, package caches) are
        // often intentionally duplicated and load-bearing; removing a copy can
        // break a project even reversibly. Those belong to repo-aware review.
        let dedupKeys: Set<String> = ["photos", "movies", "music", "documents", "downloads"]
        let dedupCandidates = filesByCategory
            .filter { dedupKeys.contains($0.key) }
            .values.flatMap { $0 }
            .filter { !Self.isAtomicBundle($0.path) }
        let duplicates = DuplicateFinder.find(in: dedupCandidates)

        let categories = Self.categoriesWithItemizedRemainder(
            bytesByKey: bytesByKey, countByKey: countByKey,
            usedBytes: used, measuredBytes: measured,
            dataRoot: root, volumeUsed: volumeUsage())

        return MacStorageReport(
            scannedAt: start,
            hostname: ProcessInfo.processInfo.hostName,
            capacityBytes: facts.capacity,
            freeBytes: facts.importantFree,
            usedBytes: used,
            purgeableBytes: purgeable,
            categories: categories,
            measuredBytes: measured,
            overMeasured: overMeasured,
            totalFileCount: totalFiles,
            snapshots: SnapshotProbe.status(),
            fullDiskAccess: FullDiskAccess.status(),
            filesByCategory: filesByCategory,
            duplicates: duplicates,
            elapsedSeconds: Date().timeIntervalSince(start))
    }

    /// The itemized (walked) file categories — one per non-empty key.
    static func fileCategories(bytesByKey: [String: Int64],
                               countByKey: [String: Int]) -> [StorageCategory] {
        bytesByKey.filter { $0.value > 0 }.map { key, bytes in
            let s = spec(key)
            return StorageCategory(key: key, name: s.name, bytes: bytes,
                                   fileCount: countByKey[key] ?? 0,
                                   symbol: s.symbol, detail: s.detail, itemized: true)
        }
    }

    /// A single non-itemized remainder entry.
    static func remainderEntry(_ key: String, _ bytes: Int64) -> StorageCategory {
        let s = spec(key)
        return StorageCategory(key: key, name: s.name, bytes: bytes, fileCount: 0,
                               symbol: s.symbol, detail: s.detail, itemized: false)
    }

    /// Turns raw per-key byte tallies into display categories plus a single
    /// reconciling remainder. Invariant: when `measured <= used`, the returned
    /// categories' bytes sum to EXACTLY `usedBytes`. Kept pure for testing.
    static func buildCategories(bytesByKey: [String: Int64],
                                countByKey: [String: Int],
                                usedBytes: Int64,
                                measuredBytes: Int64) -> [StorageCategory] {
        var out = fileCategories(bytesByKey: bytesByKey, countByKey: countByKey)
        let remainder = max(0, usedBytes - measuredBytes)
        if remainder > 0 { out.append(remainderEntry("system", remainder)) }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Like `buildCategories`, but breaks the remainder into its real parts
    /// using per-volume usage (`df`): protected/unreadable data on the data
    /// volume, the sealed macOS system volume, update volumes, VM swap, and a
    /// snapshots-and-other residual. Still reconciles EXACTLY to `usedBytes`.
    static func categoriesWithItemizedRemainder(
        bytesByKey: [String: Int64], countByKey: [String: Int],
        usedBytes: Int64, measuredBytes: Int64,
        dataRoot: String, volumeUsed: [String: Int64]) -> [StorageCategory] {

        var out = fileCategories(bytesByKey: bytesByKey, countByKey: countByKey)
        let remainder = max(0, usedBytes - measuredBytes)
        guard remainder > 0 else { return out.sorted { $0.bytes > $1.bytes } }

        // Fall back to one bucket if we can't measure the split volumes.
        guard dataRoot == "/System/Volumes/Data", !volumeUsed.isEmpty else {
            out.append(remainderEntry("system", remainder))
            return out.sorted { $0.bytes > $1.bytes }
        }

        // Assign the remainder in priority order so the pieces sum to EXACTLY
        // the remainder (no over- or under-count), even if a volume overflows.
        var budget = remainder
        func take(_ v: Int64) -> Int64 { let t = max(0, min(v, budget)); budget -= t; return t }
        func add(_ key: String, _ v: Int64) { if v > 0 { out.append(remainderEntry(key, v)) } }

        let dataUsed = volumeUsed["/System/Volumes/Data"] ?? 0
        add("protected", take(max(0, dataUsed - measuredBytes)))         // FDA gap
        add("macos", take(volumeUsed["/"] ?? 0))                          // sealed system
        add("preboot", take((volumeUsed["/System/Volumes/Preboot"] ?? 0)
                          + (volumeUsed["/System/Volumes/Update"] ?? 0)))
        add("vmswap", take(volumeUsed["/System/Volumes/VM"] ?? 0))
        add("snapshots", budget)                                          // residual

        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Per-volume used bytes via `df -k`, keyed by mount point. APFS shares
    /// container free space, so this is the reliable way to size each volume.
    func volumeUsage() -> [String: Int64] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/df")
        task.arguments = ["-k"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var out: [String: Int64] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 9, let usedK = Int64(f[2]) else { continue }
            let mount = f[8...].joined(separator: " ")
            out[mount] = usedK * 1024
        }
        return out
    }

    // MARK: - Volume facts

    struct VolumeFacts { let capacity: Int64; let importantFree: Int64; let rawFree: Int64 }

    private func volumeFacts() -> VolumeFacts {
        if let c = capacityOverride, let f = freeOverride {
            return VolumeFacts(capacity: c, importantFree: f, rawFree: rawFreeOverride ?? f)
        }
        let url = URL(fileURLWithPath: home)
        let v = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        return VolumeFacts(
            capacity: Int64(v?.volumeTotalCapacity ?? 0),
            importantFree: v?.volumeAvailableCapacityForImportantUsage ?? 0,
            rawFree: Int64(v?.volumeAvailableCapacity ?? 0))
    }
}
