import Foundation

/// Read-only scanner. Principle: a scan never mutates the computer.
/// It resolves recipe paths, measures allocated + apparent size, checks
/// process state, and honors macOS protections as hard stops.
public struct StorageScanner: Sendable {

    public var recipes: [Recipe]

    public init(recipes: [Recipe] = RecipeCatalog.all) {
        self.recipes = recipes
    }

    public func scan(progress: (@Sendable (String) -> Void)? = nil) -> ScanReport {
        let start = Date()
        let running = RunningProcessProbe.snapshot()
        var findings: [Finding] = []

        var seenPaths = Set<String>()
        for recipe in recipes {
            progress?(recipe.displayName)
            for rawPath in recipe.paths {
                for resolved in PathResolver.resolve(rawPath) {
                    // A path can match more than one glob (e.g. *ShipIt* and
                    // com.*.ShipIt) or even two recipes — report it once.
                    guard seenPaths.insert(resolved).inserted else { continue }
                    let measurement = SizeMeasurement.measure(resolved)
                    guard measurement.allocatedBytes >= recipe.thresholdBytes else { continue }
                    // Match on the FULL executable path (substring), so multi-word
                    // apps like "Microsoft Teams" / "Adobe Premiere Pro" actually
                    // trip their quit-first gate — `ps comm` truncates to 16 chars,
                    // which silently defeated exact-name matching.
                    let blockingApps = recipe.requiresQuit.filter { name in
                        let n = name.lowercased()
                        return running.contains { $0.contains(n) }
                    }
                    let blocking = !blockingApps.isEmpty
                    findings.append(Finding(
                        recipeID: recipe.id,
                        displayName: recipe.displayName,
                        group: recipe.group,
                        path: resolved,
                        allocatedBytes: measurement.allocatedBytes,
                        apparentBytes: measurement.apparentBytes,
                        riskTier: recipe.riskTier,
                        action: recipe.action,
                        explanation: recipe.explanation,
                        impact: recipe.impact,
                        recurrence: recipe.recurrence,
                        lastModified: measurement.lastModified,
                        blockingAppRunning: blocking,
                        blockingApps: blockingApps,
                        skippedProtectedPaths: measurement.skippedProtected
                    ))
                }
            }
        }

        // Drop any finding whose path is nested under another finding's path.
        // A parent recipe (e.g. ~/Library/Logs) already measures its child
        // (~/Library/Logs/DiagnosticReports), so keeping both double-counts the
        // headline "recoverable" total and shows a redundant row. Keep the
        // broadest (ancestor) finding — its cleanup covers the descendant.
        findings = Self.dropNestedFindings(findings)
        findings.sort { $0.allocatedBytes > $1.allocatedBytes }

        let volume = VolumeProbe.dataVolume()
        return ScanReport(
            scannedAt: start,
            hostname: ProcessInfo.processInfo.hostName,
            volumeTotalBytes: volume.total,
            volumeFreeBytes: volume.free,
            findings: findings,
            snapshots: SnapshotProbe.status(),
            elapsedSeconds: Date().timeIntervalSince(start)
        )
    }

    /// Remove findings that live inside another finding — their bytes are
    /// already counted in the ancestor's measurement. Ancestors (shorter paths)
    /// are considered first, so every descendant finds its parent and is dropped.
    ///
    /// Safety guard: only fold a descendant into an ancestor that is *at least as
    /// protected* (same or higher risk tier). We never drop a more-protected
    /// child under a more-permissive parent — that could sweep a Red/Orange
    /// subtree into a Green one-click clean.
    static func dropNestedFindings(_ findings: [Finding]) -> [Finding] {
        let byDepth = findings.sorted { $0.path.count < $1.path.count }
        var kept: [Finding] = []
        for f in byDepth {
            let coveredBySaferAncestor = kept.contains {
                f.path.hasPrefix($0.path + "/") && $0.riskTier >= f.riskTier
            }
            if !coveredBySaferAncestor { kept.append(f) }
        }
        return kept
    }
}

// MARK: - Path resolution (~ and single-level glob)

enum PathResolver {
    /// Expands `~` and resolves glob patterns. Deep-glob (`**`) is limited to
    /// a bounded search under home to keep scans fast.
    static func resolve(_ raw: String) -> [String] {
        let expanded = NSString(string: raw).expandingTildeInPath
        guard expanded.contains("*") else {
            return FileManager.default.fileExists(atPath: expanded) ? [expanded] : []
        }
        // `**` deep patterns are deferred to the repo-aware module (Phase 3);
        // skip them in v0 rather than walk the whole disk.
        guard !expanded.contains("**") else { return [] }

        let dir = (expanded as NSString).deletingLastPathComponent
        let pattern = (expanded as NSString).lastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return entries
            .filter { fnmatch(pattern, $0, 0) == 0 }
            .map { (dir as NSString).appendingPathComponent($0) }
    }
}

// MARK: - Size measurement

struct Measurement {
    var allocatedBytes: Int64 = 0
    var apparentBytes: Int64 = 0
    var lastModified: Date?
    var skippedProtected: [String] = []
}

enum SizeMeasurement {
    private static let keys: Set<URLResourceKey> = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .totalFileSizeKey, .fileSizeKey,
        .isRegularFileKey, .contentModificationDateKey,
    ]

    static func measure(_ path: String) -> Measurement {
        var result = Measurement()
        let url = URL(fileURLWithPath: path)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return result }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            result.lastModified = attrs[.modificationDate] as? Date
        }

        if !isDir.boolValue {
            if let values = try? url.resourceValues(forKeys: keys) {
                result.allocatedBytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                result.apparentBytes = Int64(values.totalFileSize ?? values.fileSize ?? 0)
            }
            return result
        }

        // Directory: enumerate. errorHandler records protected paths and
        // continues — "Operation not permitted" is reported, never bypassed.
        final class SkipBox { var paths: [String] = [] }
        let skips = SkipBox()
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { failedURL, _ in
                skips.paths.append(failedURL.path)
                return true // keep scanning the rest
            }
        )
        while let item = enumerator?.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            result.allocatedBytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            result.apparentBytes += Int64(values.totalFileSize ?? values.fileSize ?? 0)
        }
        result.skippedProtected = skips.paths
        return result
    }
}

// MARK: - Process + volume probes

enum RunningProcessProbe {
    /// Lowercased FULL executable paths of running processes, via `ps` (works
    /// without AppKit, so the CLI stays usable over SSH; the app can layer
    /// NSWorkspace later). We use `comm=` (full path, no header, untruncated)
    /// rather than `-c comm` (16-char accounting name) so callers can substring
    /// -match multi-word app names like "Microsoft Teams" reliably.
    static func snapshot() -> Set<String> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        })
    }
}

/// Public read-only access to the data volume's free space, so the app can
/// measure the *actual* space freed by a purge (moving to quarantine frees
/// nothing — only permanent deletion does).
public enum Volume {
    public static func freeBytes() -> Int64 { VolumeProbe.dataVolume().free }
}

enum VolumeProbe {
    static func dataVolume() -> (total: Int64, free: Int64) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return (0, 0) }
        return (
            Int64(values.volumeTotalCapacity ?? 0),
            values.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }
}
