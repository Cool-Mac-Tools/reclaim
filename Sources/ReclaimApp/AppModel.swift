import Foundation
import SwiftUI
import ReclaimCore

/// The app's single source of truth. One unified scan runs every ReclaimCore
/// capability (recipes, orphans, personal review) at once and merges the
/// results into a single actionable list — "one scan → one click → done."
@MainActor
final class AppModel: ObservableObject {

    enum Section: String, CaseIterable, Identifiable {
        case scan       = "Reclaim"
        case myMac      = "My Mac"
        case quarantine = "Quarantine"
        case history    = "History"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .scan:       "arrow.clockwise"
            case .myMac:      "internaldrive"
            case .quarantine: "arrow.uturn.backward.circle"
            case .history:    "chart.bar.xaxis"
            }
        }
    }

    @Published var section: Section = .scan

    // Unified scan state
    @Published var scanning = false
    @Published var hasScanned = false
    @Published var scanReport: ScanReport?
    @Published var orphans: [Orphan] = []
    @Published var review: JudgmentReport?
    @Published var freeBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0

    // "My Mac" whole-disk storage map (read-only overview of everything).
    @Published var mapping = false
    @Published var hasMapped = false
    @Published var mapReport: MacStorageReport?
    @Published var mapProgressFiles = 0   // live file count during the walk

    /// Paths the user has chosen to clean. Seeded with the safe set after a scan.
    @Published var selected: Set<String> = []

    // Quarantine
    @Published var sessions: [QuarantineSummary] = []
    @Published var lifetimeReclaimed: Int64 = 0
    /// Full cleanup history (newest first), for the History timeline.
    @Published var history: [CleanupLedgerEntry] = []
    @Published var lastStagedBytes: Int64 = 0     // moved to quarantine, not yet freed
    @Published var lastFreedBytes: Int64?         // actual space freed by last purge
    @Published var lastPurgeSnapshotLag = false
    @Published var busy: String?

    // Full Disk Access — gates accurate storage showing *and* saving.
    @Published var fdaStatus: FullDiskAccess.Status = .undetermined
    var needsFullDiskAccess: Bool { fdaStatus == .denied }

    /// Total bytes sitting in quarantine right now — reclaimable by emptying.
    var stagedBytes: Int64 { sessions.reduce(0) { $0 + $1.bytes } }

    struct QuarantineSummary: Identifiable {
        let id: String; let count: Int; let bytes: Int64
    }

    /// Drives the celebratory share sheet shown after quarantine is emptied.
    struct Celebration: Identifiable {
        let id = UUID(); let freed: Int64; let lifetime: Int64
    }
    @Published var celebration: Celebration?

    /// A single row in the unified results list, from any source.
    struct CleanItem: Identifiable, Sendable {
        let id: String            // absolute path
        let name: String
        let detail: String        // plain-language rationale
        let bytes: Int64
        let tier: RiskTier
        let source: String        // recipe id / "orphan" / "review"
        let selectable: Bool      // false for Red, running apps, info-only rows
        let safe: Bool            // part of the pre-selected one-click set
        var blockingApps: [String] = []  // running apps that block this item
    }

    // MARK: - Full Disk Access

    /// Re-probe FDA off the main thread. Also registers Reclaim in the FDA list
    /// on first denied attempt, so the user just flips a switch. Call at launch
    /// and whenever the app regains focus (e.g. back from System Settings).
    func refreshFDA() {
        Task {
            let status = await Task.detached(priority: .utility) { FullDiskAccess.status() }.value
            self.fdaStatus = status
        }
    }

    /// Jump straight to the Full Disk Access pane in System Settings.
    func openFDASettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Unified scan

    func runEverything() {
        guard !scanning else { return }
        // A scan here also refreshes the "My Mac" overview, so both tabs stay
        // in sync — you can start from either one.
        mapMac()
        scanning = true
        hasScanned = false
        scanReport = nil; orphans = []; review = nil; selected = []

        Task {
            async let scan = Self.doScan()
            async let orph = Self.doOrphans()
            async let rev  = Self.doReview()
            let (s, o, r) = await (scan, orph, rev)
            self.scanReport = s
            self.orphans = o
            self.review = r
            self.freeBytes = s.volumeFreeBytes
            self.totalBytes = s.volumeTotalBytes
            self.selected = Set(self.items.filter(\.safe).map(\.id))
            self.scanning = false
            self.hasScanned = true
        }
    }

    /// Build the whole-disk "My Mac" map. Independent of the recipe scan so it
    /// can be launched from either the Scan tab (via `runEverything`) or the
    /// My Mac tab directly.
    func mapMac() {
        guard !mapping else { return }
        mapping = true
        mapProgressFiles = 0
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                MacStorageMap().run(progress: { files in
                    Task { @MainActor in self.mapProgressFiles = files }
                })
            }.value
            self.mapReport = report
            // Remember the file count so the next scan's progress bar can fill
            // against a real target instead of guessing.
            UserDefaults.standard.set(report.totalFileCount, forKey: Self.lastFileCountKey)
            self.mapping = false
            self.hasMapped = true
        }
    }

    private static let lastFileCountKey = "reclaim.lastFileCount"
    /// Expected total files for the progress bar — the last scan's count, or a
    /// sensible default the first time.
    var expectedFileTotal: Int {
        let saved = UserDefaults.standard.integer(forKey: Self.lastFileCountKey)
        return saved > 10_000 ? saved : 1_200_000
    }

    private nonisolated static func doScan() async -> ScanReport {
        await Task.detached(priority: .userInitiated) { StorageScanner().scan() }.value
    }
    private nonisolated static func doOrphans() async -> [Orphan] {
        await Task.detached(priority: .userInitiated) { OrphanScanner().scan() }.value
    }
    private nonisolated static func doReview() async -> JudgmentReport {
        await Task.detached(priority: .userInitiated) { JudgmentScanner().scan() }.value
    }

    /// The merged, de-duplicated results list.
    var items: [CleanItem] {
        var out: [CleanItem] = []

        for f in scanReport?.findings ?? [] {
            let safe = f.riskTier == .green && !f.blockingAppRunning
            let selectable = f.riskTier != .red && !f.blockingAppRunning
            let note = f.blockingAppRunning ? "Quit the owning app first — then this can be cleaned. "
                     : f.riskTier == .red ? "System-protected. Reclaim reports it but never removes it. " : ""
            out.append(CleanItem(id: f.path, name: f.displayName, detail: note + f.explanation,
                                 bytes: f.allocatedBytes, tier: f.riskTier, source: f.recipeID,
                                 selectable: selectable, safe: safe, blockingApps: f.blockingApps))
        }
        for o in orphans where o.confidence == .likelyOrphan {
            out.append(CleanItem(id: o.path, name: "Leftover: \(o.folderName)",
                                 detail: "Data from an app that's no longer installed (\(o.area)). Reversible.",
                                 bytes: o.allocatedBytes, tier: .blue, source: "orphan",
                                 selectable: true, safe: true))
        }
        for s in review?.suggestions ?? [] {
            out.append(CleanItem(id: s.path, name: (s.path as NSString).lastPathComponent,
                                 detail: s.rationale, bytes: s.sizeBytes, tier: s.riskTier,
                                 source: "review", selectable: true, safe: false))
        }
        // De-dup by path (orphans already exclude recipe paths, but be safe).
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
                  .sorted { ($0.safe ? 1 : 0, $0.bytes) > ($1.safe ? 1 : 0, $1.bytes) }
    }

    var safeReclaimBytes: Int64 { items.filter(\.safe).reduce(0) { $0 + $1.bytes } }
    /// Everything worth reviewing — history, personal files, and items an open
    /// app is currently using (blocked, but still reclaimable once it quits).
    /// Only truly protected (Red) items are excluded.
    var reviewBytes: Int64 { items.filter { !$0.safe && $0.tier != .red }.reduce(0) { $0 + $1.bytes } }
    var selectedBytes: Int64 { items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    /// Accumulation clusters are multi-file personal pile-ups — shown as
    /// insight, not one-click cleanable (each file needs its own look).
    var clusters: [Cluster] { review?.clusters ?? [] }

    // MARK: - Clean

    func cleanSelected() {
        let chosen = items.filter { selected.contains($0.id) && $0.selectable }
        reclaim(chosen.map { CleanupTarget(path: $0.id, riskTier: $0.tier, source: $0.source) })
    }

    /// The shared clean pipeline used by the main list and the media browser.
    /// Moves targets to the reversible quarantine, records the ledger, then
    /// jumps to Quarantine so the stage→empty step is obvious, and rescans.
    func reclaim(_ targets: [CleanupTarget]) {
        guard !targets.isEmpty, busy == nil else { return }
        let bytes = targets.count
        busy = "Reclaiming \(bytes) item(s)…"
        Task {
            let entry = await Task.detached(priority: .userInitiated) {
                let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
                let result = CleanupExecutor(greenOnly: false).run(targets, sessionID: df.string(from: Date()))
                try? LedgerStore().append(result)
                return result
            }.value
            self.lastStagedBytes = entry.quarantinedBytes
            self.lastFreedBytes = nil          // nothing freed yet — it's staged
            self.busy = nil
            self.loadQuarantine()
            self.section = .quarantine  // show the staged result + "Empty & Free Space"
            self.runEverything()       // rescan so cleaned items drop off the list
        }
    }

    func toggle(_ id: String, _ on: Bool) {
        if on { selected.insert(id) } else { selected.remove(id) }
    }

    // Media browser: which cluster's files are being browsed in the sheet.
    @Published var openCluster: Cluster?

    // MARK: - Quarantine

    func loadQuarantine() {
        sessions = Quarantine.sessions().map { id in
            let entries = (try? Quarantine(sessionID: id).manifest()) ?? []
            return QuarantineSummary(id: id, count: entries.count, bytes: entries.reduce(0) { $0 + $1.bytes })
        }
        let ledger = LedgerStore()
        lifetimeReclaimed = ledger.lifetimeQuarantinedBytes
        history = ledger.all().reversed()   // newest first
    }

    func restore(_ id: String) {
        busy = "Restoring \(id)…"
        Task {
            _ = await Task.detached { try? Quarantine(sessionID: id).restoreAll() }.value
            self.busy = nil; self.loadQuarantine()
        }
    }

    func purge(_ id: String) { emptyQuarantine(ids: [id], label: "Deleting \(id)…") }

    /// Permanently delete every quarantine session and measure the space that
    /// actually came back (a move frees nothing; only this does).
    func emptyAll() {
        guard !sessions.isEmpty else { return }
        emptyQuarantine(ids: sessions.map(\.id), label: "Freeing space…")
    }

    private func emptyQuarantine(ids: [String], label: String) {
        guard busy == nil else { return }
        // The headline "you freed X" number = what the user actually cleared.
        // It's robust to APFS snapshot lag (free-space delta can trail reality).
        let purged = sessions.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.bytes }
        busy = label
        Task {
            let (freed, lag) = await Task.detached(priority: .userInitiated) { () -> (Int64, Bool) in
                let before = Volume.freeBytes()
                for id in ids { try? Quarantine(sessionID: id).purge() }
                let after = Volume.freeBytes()
                let freed = after - before
                let snaps = SnapshotProbe.status().count
                // Snapshot lag: we deleted real data but free space barely moved.
                return (freed, snaps > 0 && freed < 100 * 1024 * 1024)
            }.value
            self.lastFreedBytes = max(0, freed)
            self.lastPurgeSnapshotLag = lag
            self.busy = nil
            self.loadQuarantine()
            if purged > 0 {
                self.celebration = Celebration(freed: purged, lifetime: self.lifetimeReclaimed)
            }
        }
    }
}

// MARK: - Shared view helpers

extension RiskTier {
    var color: Color {
        switch self {
        case .green: .green; case .blue: .blue; case .yellow: .yellow
        case .orange: .orange; case .red: .red
        }
    }
    var plainLabel: String {
        switch self {
        case .green:  "Safe to rebuild"
        case .blue:   "Reversible"
        case .yellow: "History — you may want to keep"
        case .orange: "Personal — review carefully"
        case .red:    "Protected — never removed"
        }
    }
}

enum Fmt { static func bytes(_ b: Int64) -> String { ByteFormatter.string(b) } }
