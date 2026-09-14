import Foundation

/// APFS local-snapshot awareness. Research-verified facts (July 2026):
/// - macOS makes hourly Time Machine snapshots, kept ~24h, plus pre-update ones.
/// - Deleted files stay pinned by snapshots; freed space may NOT appear until
///   the snapshot dies. macOS does NOT reliably purge purgeable space.
/// - Snapshots are invisible to file-level scanning — enumerable only via
///   `tmutil listlocalsnapshots`.
/// Implication: verification must never treat "space didn't free" as recipe
/// failure while snapshots exist; offer snapshot thinning as a follow-up.
public struct SnapshotStatus: Codable, Sendable {
    public let snapshotNames: [String]
    public var count: Int { snapshotNames.count }

    /// True when deletions may not immediately show as free space.
    public var mayPinDeletedBlocks: Bool { !snapshotNames.isEmpty }
}

public enum SnapshotProbe {
    /// Lists local Time Machine snapshots on the data volume. Read-only.
    public static func status() -> SnapshotStatus {
        guard let text = ReadOnlyCommand.output("/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"]) else { return SnapshotStatus(snapshotNames: []) }
        let names = text.split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("com.apple.") }
        return SnapshotStatus(snapshotNames: names)
    }
}
