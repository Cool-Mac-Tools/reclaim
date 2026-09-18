import Foundation

/// Append-only history of cleanup sessions at ~/.reclaim/ledger.json.
/// This is the durable record behind "prove the outcome" and the growth
/// story ("Reclaim has recovered X GB across N sessions").
public struct LedgerStore: Sendable {
    public let path: String

    public init(home: String = NSHomeDirectory()) {
        self.path = (home as NSString).appendingPathComponent(".reclaim/ledger.json")
    }

    public func all() throws -> [CleanupLedgerEntry] {
        try DurableJSONStore<[CleanupLedgerEntry]>(path: path).read(default: [])
    }

    public func append(_ entry: CleanupLedgerEntry) throws {
        try DurableJSONStore<[CleanupLedgerEntry]>(path: path).update(default: []) { entries in
            if !entries.contains(where: { $0.sessionID == entry.sessionID }) { entries.append(entry) }
        }
    }

    /// Lifetime bytes moved to quarantine across all sessions.
    public var lifetimeQuarantinedBytes: Int64 {
        get throws { try all().reduce(0) { $0 + $1.quarantinedBytes } }
    }
}
