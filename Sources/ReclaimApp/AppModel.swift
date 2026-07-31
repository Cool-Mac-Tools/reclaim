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
        case ai         = "AI"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .scan:       "arrow.clockwise"
            case .myMac:      "internaldrive"
            case .quarantine: "arrow.uturn.backward.circle"
            case .history:    "chart.bar.xaxis"
            case .ai:         "sparkles"
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
    /// Tool binaries found on this Mac (npm, brew…) — gates the CLI cleanups.
    @Published var availableTools: Set<String> = []

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
        let entries: [QuarantineEntry]
    }

    /// Drives the celebratory share sheet shown after quarantine is emptied.
    struct Celebration: Identifiable {
        let id = UUID(); let freed: Int64; let lifetime: Int64
    }
    @Published var celebration: Celebration?

    /// One-shot message shown after a reclaim/restore so outcomes (and skips)
    /// are never silent.
    @Published var actionAlert: String?

    // MARK: - AI explain

    struct AIRequest: Identifiable {
        let id = UUID(); let title: String; let system: String; let user: String
    }
    /// When set, the AI explain popup is shown for this item.
    @Published var aiRequest: AIRequest?

    func explainItem(_ item: CleanItem) { aiRequest = Self.request(forItem: item) }

    // Pure builders — usable from views that present the AI sheet themselves
    // (sheets can't trigger a sheet on the window behind them).
    static func request(forItem item: CleanItem) -> AIRequest {
        AIRequest(title: item.name, system: AIPrompt.system,
            user: AIPrompt.user(name: item.name, location: item.id, size: Fmt.bytes(item.bytes),
                                tier: item.tier.plainLabel, detail: item.detail,
                                impact: item.impact, recurrence: item.recurrence))
    }
    static func request(forFile file: ClusterFile, category: String) -> AIRequest {
        let name = (file.path as NSString).lastPathComponent
        return AIRequest(title: name, system: AIPrompt.system,
            user: AIPrompt.user(name: name, location: file.path, size: Fmt.bytes(file.bytes),
                                tier: category, detail: "", impact: "", recurrence: ""))
    }
    static func request(forNode node: FileNode, category: String) -> AIRequest {
        AIRequest(title: node.name, system: AIPrompt.system,
            user: AIPrompt.user(name: node.name, location: node.path, size: Fmt.bytes(node.bytes),
                                tier: category, detail: node.isDirectory ? "A folder." : "",
                                impact: "", recurrence: ""))
    }

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
        var impact: String = ""          // what deletion changes / re-downloads
        var recurrence: String = ""      // whether it grows back
        var isDirectory: Bool = false    // can be expanded to reveal contents
    }

    /// A child target discovered by expanding a folder — registered so the
    /// clean action can act on individually-selected parts.
    struct SelTarget { let target: CleanupTarget; let bytes: Int64 }
    @Published var extraTargets: [String: SelTarget] = [:]

    /// Record the removable children revealed when a folder is expanded, so
    /// selecting them feeds the same clean flow as top-level items.
    func registerNodes(_ nodes: [FileNode], tier: RiskTier, source: String) {
        for n in nodes where CleanupExecutor.isRemovable(n.path) && !MacStorageMap.isAtomicBundle(n.path) {
            extraTargets[n.path] = SelTarget(
                target: CleanupTarget(path: n.path, riskTier: tier, source: source), bytes: n.bytes)
        }
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
        scanReport = nil; orphans = []; review = nil; selected = []; extraTargets = [:]

        Task {
            async let scan = Self.doScan()
            async let orph = Self.doOrphans()
            async let rev  = Self.doReview()
            let (s, o, r) = await (scan, orph, rev)
            // Which tool commands are actually usable — resolved via the login
            // shell so nvm/pyenv/Homebrew paths are found.
            let neededTools = Set(s.findings
                .filter { $0.action == .supportedCLI }
                .compactMap { SupportedCLI.command(for: $0.recipeID)?.tool })
            let avail = await Task.detached { SupportedCLI.availableTools(among: neededTools) }.value

            self.scanReport = s
            self.orphans = o
            self.review = r
            self.availableTools = avail
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
            // Findings with a usable tool command are handled in the CLI section,
            // not by quarantine — skip them here.
            if f.action == .supportedCLI, let cmd = SupportedCLI.command(for: f.recipeID),
               availableTools.contains(cmd.tool) { continue }
            // Can we actually remove it? Root/other-owned items (e.g. a cache
            // made by `sudo npm`) can't be touched without admin — mark them
            // non-selectable with a clear reason instead of failing silently.
            let removable = CleanupExecutor.isRemovable(f.path)
            // Pre-select both Green (regenerable) and Blue (reversible/
            // re-downloadable) — both are safe and undoable via quarantine.
            // Yellow (history) and Orange (personal) stay review-only.
            let safe = (f.riskTier == .green || f.riskTier == .blue)
                     && !f.blockingAppRunning && removable
            let selectable = f.riskTier != .red && !f.blockingAppRunning && removable
            let note = !removable ? "Owned by the system or another account — needs admin rights to remove. "
                     : f.blockingAppRunning ? "Quit the owning app first — then this can be cleaned. "
                     : f.riskTier == .red ? "System-protected. Reclaim reports it but never removes it. " : ""
            out.append(CleanItem(id: f.path, name: f.displayName, detail: note + f.explanation,
                                 bytes: f.allocatedBytes, tier: f.riskTier, source: f.recipeID,
                                 selectable: selectable, safe: safe, blockingApps: f.blockingApps,
                                 impact: f.impact, recurrence: f.recurrence,
                                 isDirectory: DirLister.isDirectory(f.path)))
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

    /// Tool-command cleanups available this scan (npm/brew/…), one per finding
    /// whose recipe prefers its tool's own cleanup and whose tool is installed.
    struct CLIItem: Identifiable {
        let id: String; let name: String; let bytes: Int64; let command: SupportedCLI.Command
    }
    var cliItems: [CLIItem] {
        (scanReport?.findings ?? []).compactMap { f in
            guard f.action == .supportedCLI,
                  let cmd = SupportedCLI.command(for: f.recipeID),
                  availableTools.contains(cmd.tool) else { return nil }
            return CLIItem(id: cmd.recipeID, name: f.displayName, bytes: f.allocatedBytes, command: cmd)
        }
    }

    /// Run a tool's own cleanup command (irreversible — not quarantine).
    func runCLI(_ command: SupportedCLI.Command) {
        guard busy == nil else { return }
        busy = "Running \(command.invocation)…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SupportedCLI.run(command)
            }.value
            self.busy = nil
            if result.succeeded {
                self.actionAlert = "Ran `\(command.invocation)`.\nFreed \(Fmt.bytes(result.freedBytes))."
            } else {
                self.actionAlert = "`\(command.invocation)` didn't finish cleanly:\n\(result.output)"
            }
            self.runEverything()
        }
    }

    var safeReclaimBytes: Int64 { items.filter(\.safe).reduce(0) { $0 + $1.bytes } }
    /// Everything worth reviewing — history, personal files, and items an open
    /// app is currently using (blocked, but still reclaimable once it quits).
    /// Only truly protected (Red) items are excluded.
    var reviewBytes: Int64 { items.filter { !$0.safe && $0.tier != .red }.reduce(0) { $0 + $1.bytes } }
    var selectedBytes: Int64 {
        var total = items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
        let itemIDs = Set(items.map(\.id))
        for (path, st) in extraTargets where selected.contains(path) && !itemIDs.contains(path) {
            total += st.bytes
        }
        return total
    }

    /// Accumulation clusters are multi-file personal pile-ups — shown as
    /// insight, not one-click cleanable (each file needs its own look).
    var clusters: [Cluster] { review?.clusters ?? [] }

    // MARK: - Clean

    func cleanSelected() {
        var targets = items.filter { selected.contains($0.id) && $0.selectable }
            .map { CleanupTarget(path: $0.id, riskTier: $0.tier, source: $0.source) }
        // Include individually-selected expanded children.
        for (path, st) in extraTargets where selected.contains(path) { targets.append(st.target) }
        var seen = Set<String>()
        reclaim(targets.filter { seen.insert($0.path).inserted })
    }

    /// The shared clean pipeline used by the main list and the media browser.
    /// Moves targets to the reversible quarantine, records the ledger, then
    /// jumps to Quarantine so the stage→empty step is obvious, and rescans.
    func reclaim(_ targets: [CleanupTarget]) {
        guard !targets.isEmpty, busy == nil else { return }
        busy = "Reclaiming \(targets.count) item(s)…"
        Task {
            let entry = await Task.detached(priority: .userInitiated) {
                let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
                return CleanupExecutor(greenOnly: false).run(targets, sessionID: df.string(from: Date()))
            }.value
            let moved = entry.results.filter { $0.status == .quarantined }
            let skipped = entry.results.filter { $0.status != .quarantined }

            if !moved.isEmpty {
                try? LedgerStore().append(entry)          // only log real sessions
                self.lastStagedBytes = entry.quarantinedBytes
                self.lastFreedBytes = nil                 // staged, not yet freed
            } else {
                // Nothing moved — don't leave an empty session dir behind.
                try? Quarantine(sessionID: entry.sessionID).purge()
            }
            self.busy = nil
            self.loadQuarantine()
            self.actionAlert = Self.reclaimSummary(moved: moved, skipped: skipped)
            if !moved.isEmpty { self.section = .quarantine }
            self.runEverything()   // rescan so cleaned items drop off the list
        }
    }

    /// Honest, human summary of a reclaim attempt — including why items were skipped.
    private static func reclaimSummary(moved: [ActionResult], skipped: [ActionResult]) -> String {
        var lines: [String] = []
        if !moved.isEmpty {
            let bytes = moved.reduce(0) { $0 + $1.bytes }
            lines.append("Moved \(moved.count) item(s) — \(Fmt.bytes(bytes)) — to quarantine.")
        }
        if !skipped.isEmpty {
            lines.append("Couldn't move \(skipped.count):")
            for (reason, group) in Dictionary(grouping: skipped, by: \.detail).prefix(4) {
                lines.append("• \(group.count) — \(reason)")
            }
        }
        if lines.isEmpty { lines.append("Nothing to reclaim.") }
        return lines.joined(separator: "\n")
    }

    func toggle(_ id: String, _ on: Bool) {
        if on { selected.insert(id) } else { selected.remove(id) }
    }

    /// Quit the app(s) blocking an item, then clean it — removing the "quit the
    /// app and rescan" friction. Graceful termination (the app can still prompt
    /// to save). Then the item is no longer blocked and moves to quarantine.
    func quitAndClean(_ item: CleanItem) {
        guard !item.blockingApps.isEmpty, busy == nil else { return }
        busy = "Quitting \(item.blockingApps.joined(separator: ", "))…"
        Task {
            await Self.quitApps(item.blockingApps)
            self.busy = nil
            self.reclaim([CleanupTarget(path: item.id, riskTier: item.tier, source: item.source)])
        }
    }

    /// Gracefully quit running apps by display name and wait (briefly) for them
    /// to actually exit.
    private static func quitApps(_ names: [String]) async {
        let ws = NSWorkspace.shared
        func matches(_ app: NSRunningApplication) -> Bool {
            let n = app.localizedName ?? ""
            return names.contains { n == $0 || n.localizedCaseInsensitiveContains($0) }
        }
        ws.runningApplications.filter(matches).forEach { $0.terminate() }
        for _ in 0..<25 {   // up to ~5s
            if !ws.runningApplications.contains(where: matches) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // Media browser: which cluster's files are being browsed in the sheet.
    @Published var openCluster: Cluster?

    // MARK: - Photos library (PhotoKit detail)

    /// The last full library walk — largest assets plus library-wide totals.
    /// Nil until the browser is first opened.
    @Published var photoScan: PhotoLibrary.Scan?
    @Published var photosLoading = false
    @Published var photoProgress: (done: Int, total: Int) = (0, 0)
    /// True when Photos access was refused — the browser shows how to grant it.
    @Published var photoAuthDenied = false

    var photoAssets: [PhotoLibrary.Asset] { photoScan?.assets ?? [] }

    /// Read the Photos library via PhotoKit (off-main; may prompt for access on
    /// first use). Cached after the first successful load unless `force`.
    func loadPhotos(force: Bool = false) {
        guard !photosLoading else { return }
        if photoScan != nil && !force { return }
        photosLoading = true
        photoAuthDenied = false
        photoProgress = (0, 0)
        Task {
            let scan = await Task.detached(priority: .userInitiated) { () -> PhotoLibrary.Scan in
                PhotoLibrary.loadAssets(progress: { done, total in
                    Task { @MainActor in self.photoProgress = (done, total) }
                })
            }.value
            self.photoScan = scan
            self.photosLoading = false
            if scan.totalCount == 0 && !PhotoLibrary.isAuthorized {
                self.photoAuthDenied = true
            }
        }
    }

    /// Move selected assets to Photos' Recently Deleted (recoverable 30 days).
    /// macOS shows its own confirmation panel; we record the outcome honestly and
    /// log it to the ledger so History and lifetime totals include it.
    func deletePhotos(ids: Set<String>) {
        guard !ids.isEmpty, busy == nil else { return }
        let doomed = photoAssets.filter { ids.contains($0.id) }
        guard !doomed.isEmpty else { return }
        busy = "Removing \(doomed.count) item(s) from Photos…"
        Task {
            let outcome = await PhotoLibrary.delete(ids: Array(ids))
            self.busy = nil
            switch outcome {
            case .deleted(let n):
                let removed = Set(doomed.map(\.id))
                self.photoScan?.assets.removeAll { removed.contains($0.id) }
                let bytes = doomed.reduce(0) { $0 + $1.bytes }
                self.photoScan?.totalBytes -= bytes
                self.logPhotoDeletion(doomed)
                self.actionAlert = "Moved \(n) item(s) — \(Fmt.bytes(bytes)) — to Photos → Recently Deleted."
                    + "\nRecover them in Photos within 30 days; empty Recently Deleted to free the space now."
                self.loadQuarantine()   // refresh lifetime reclaimed + History
            case .cancelled:
                self.actionAlert = "No changes made — the deletion was cancelled."
            case .nothingFound:
                self.actionAlert = "Those items are no longer in your library."
            }
        }
    }

    /// Record a photo removal in the same ledger as file cleanups, so the History
    /// tab and lifetime-reclaimed total reflect it. Recently-Deleted holds the
    /// bytes for 30 days, so free space doesn't move yet — recorded honestly
    /// (freeBefore == freeAfter), same as staged quarantine.
    private func logPhotoDeletion(_ assets: [PhotoLibrary.Asset]) {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let results = assets.map {
            ActionResult(path: "Photos Library / \($0.filename)",
                         status: .quarantined, bytes: $0.bytes,
                         detail: "Moved to Photos → Recently Deleted (recoverable 30 days)")
        }
        let free = Volume.freeBytes()
        let entry = CleanupLedgerEntry(
            sessionID: "photos-" + df.string(from: Date()), startedAt: Date(),
            results: results, freeBeforeBytes: free, freeAfterBytes: free, snapshotsPresent: 0)
        try? LedgerStore().append(entry)
    }

    // MARK: - Quarantine

    func loadQuarantine() {
        var summaries: [QuarantineSummary] = []
        for id in Quarantine.sessions() {
            let entries = (try? Quarantine(sessionID: id).manifest()) ?? []
            // Purge stale empty sessions (left by failed moves) so they don't
            // show as confusing "0 items" rows.
            guard !entries.isEmpty else { try? Quarantine(sessionID: id).purge(); continue }
            summaries.append(QuarantineSummary(
                id: id, count: entries.count,
                bytes: entries.reduce(0) { $0 + $1.bytes }, entries: entries))
        }
        sessions = summaries
        let ledger = LedgerStore()
        lifetimeReclaimed = ledger.lifetimeQuarantinedBytes
        history = ledger.all().reversed()   // newest first
    }

    func restore(_ id: String) {
        busy = "Restoring…"
        Task {
            let result = await Task.detached {
                (try? Quarantine(sessionID: id).restoreAll()) ?? (restored: [], failed: [])
            }.value
            self.busy = nil
            if result.failed.isEmpty {
                try? Quarantine(sessionID: id).purge()   // fully restored → clear the session
                self.actionAlert = "Restored \(result.restored.count) item(s) to their original location."
            } else {
                self.actionAlert = "Restored \(result.restored.count). Couldn't restore "
                    + "\(result.failed.count) — a newer version may already exist at the "
                    + "original spot, or the file is missing."
            }
            self.loadQuarantine()
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
