import Foundation
import Darwin

/// The outcome of attempting to act on one target.
public struct ActionResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case quarantined      // moved to the reversible vault
        case skippedProtected // macOS said no — honored as a hard stop
        case skippedAppRunning
        case skippedNotAllowed // policy refused (e.g. Red tier, non-Green in V1)
        case failed
    }
    public let path: String
    public let status: Status
    public let bytes: Int64
    public let detail: String

    public init(path: String, status: Status, bytes: Int64, detail: String) {
        self.path = path
        self.status = status
        self.bytes = bytes
        self.detail = detail
    }
}

/// A cleanup session's full record — the ledger entry (plan §10: "prove the
/// outcome"). Honest by construction: it records skips and failures, and it
/// separates requested/quarantined bytes from the actual free-space delta,
/// which can lag when APFS snapshots pin the freed blocks.
public struct CleanupLedgerEntry: Codable, Sendable {
    public let sessionID: String
    public let startedAt: Date
    public let results: [ActionResult]
    public let freeBeforeBytes: Int64
    public let freeAfterBytes: Int64
    public let snapshotsPresent: Int

    public init(sessionID: String, startedAt: Date, results: [ActionResult],
                freeBeforeBytes: Int64, freeAfterBytes: Int64, snapshotsPresent: Int) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.results = results
        self.freeBeforeBytes = freeBeforeBytes
        self.freeAfterBytes = freeAfterBytes
        self.snapshotsPresent = snapshotsPresent
    }

    public var quarantinedBytes: Int64 {
        results.filter { $0.status == .quarantined }.reduce(0) { $0 + $1.bytes }
    }
    public var freeDelta: Int64 { freeAfterBytes - freeBeforeBytes }
    /// True when we freed data but the volume's free space didn't rise to match
    /// — the snapshot-pinning case the research flagged.
    public var freedSpaceLagging: Bool {
        quarantinedBytes > 0 && freeDelta < quarantinedBytes / 2 && snapshotsPresent > 0
    }
}

/// A target to act on: a path plus the safety context needed to decide.
public struct CleanupTarget: Sendable {
    public let path: String
    public let riskTier: RiskTier
    public let source: String
    public let blockingAppRunning: Bool

    public init(path: String, riskTier: RiskTier, source: String, blockingAppRunning: Bool = false) {
        self.path = path
        self.riskTier = riskTier
        self.source = source
        self.blockingAppRunning = blockingAppRunning
    }
}

/// Executes cleanup by moving targets to quarantine. Deliberately conservative:
///   • Red tier is NEVER touched.
///   • With `greenOnly` (the V1 default), only Green auto-runs; anything else
///     is skipped as not-allowed and must be handled by explicit user review.
///   • A running blocking app is a skip, not a force-quit.
///   • Verification measures the real free-space delta afterward.
public struct CleanupExecutor: Sendable {
    public let home: String
    public let greenOnly: Bool

    public init(home: String = NSHomeDirectory(), greenOnly: Bool = true) {
        self.home = home
        self.greenOnly = greenOnly
    }

    /// Whether the current user can actually move/remove this path. Items owned
    /// by root or another account (e.g. a cache created by `sudo npm`) can't be
    /// touched without admin rights — no amount of Full Disk Access changes Unix
    /// ownership. We detect this up front so it's an honest skip, not a silent
    /// move that fails with EPERM and leaves the item sitting in the list.
    public static func isRemovable(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return st.st_uid == getuid()
    }

    public func run(_ targets: [CleanupTarget], sessionID: String,
                    now: Date = Date()) -> CleanupLedgerEntry {
        let freeBefore = VolumeProbe.dataVolume().free
        let quarantine = Quarantine(home: home, sessionID: sessionID)
        var results: [ActionResult] = []

        for target in targets {
            // Policy gates, in order of severity.
            if target.riskTier == .red {
                results.append(.init(path: target.path, status: .skippedNotAllowed,
                                     bytes: 0, detail: "System-protected (Red) — never removed."))
                continue
            }
            if greenOnly && target.riskTier != .green {
                results.append(.init(path: target.path, status: .skippedNotAllowed, bytes: 0,
                                     detail: "\(target.riskTier.displayName) needs explicit review; not auto-cleaned."))
                continue
            }
            if target.blockingAppRunning {
                results.append(.init(path: target.path, status: .skippedAppRunning,
                                     bytes: 0, detail: "Owning app is running — quit it first."))
                continue
            }
            guard FileManager.default.isReadableFile(atPath: target.path) else {
                results.append(.init(path: target.path, status: .skippedProtected, bytes: 0,
                                     detail: "Operation not permitted or missing — skipped, not forced."))
                continue
            }
            guard Self.isRemovable(target.path) else {
                results.append(.init(path: target.path, status: .skippedProtected, bytes: 0,
                                     detail: "Owned by the system or another account — needs admin rights to remove."))
                continue
            }
            do {
                let entry = try quarantine.store(target.path, source: target.source, now: now)
                // Verify the original location is actually clear.
                let gone = !FileManager.default.fileExists(atPath: target.path)
                results.append(.init(
                    path: target.path,
                    status: gone ? .quarantined : .failed,
                    bytes: entry.bytes,
                    detail: gone ? "Moved to quarantine (reversible)." : "Move reported success but path still present."))
            } catch {
                results.append(.init(path: target.path, status: .failed, bytes: 0,
                                     detail: "\(error)"))
            }
        }

        let freeAfter = VolumeProbe.dataVolume().free
        return CleanupLedgerEntry(
            sessionID: sessionID, startedAt: now, results: results,
            freeBeforeBytes: freeBefore, freeAfterBytes: freeAfter,
            snapshotsPresent: SnapshotProbe.status().count)
    }
}
