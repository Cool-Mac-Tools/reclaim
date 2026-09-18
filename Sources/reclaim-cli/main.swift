import Foundation
import ReclaimCore

// reclaim — read-only storage scan (Phase 0 concierge tool)
//
//   reclaim scan            human-readable report
//   reclaim scan --json     machine-readable report (for the ledger / app)
//   reclaim recipes         list the recipe catalog
//
// This tool NEVER deletes anything. It scans, classifies, and explains.

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "scan"
let wantsJSON = args.contains("--json")
let verbose = args.contains("--verbose") || args.contains("-v")

func tierBadge(_ tier: RiskTier) -> String {
    switch tier {
    case .green: "🟢"; case .blue: "🔵"; case .yellow: "🟡"; case .orange: "🟠"; case .red: "🔴"
    }
}

switch command {
case "workspace-event":
    let values = Array(args.dropFirst())
    func option(_ name: String) -> String? {
        guard let i = values.firstIndex(of: name), i + 1 < values.count else { return nil }
        return values[i + 1]
    }
    guard let rawKind = option("--kind"), let kind = WorkspaceKind(rawValue: rawKind),
          [.file, .terminal, .agent, .task].contains(kind),
          let entityID = option("--id"), let title = option("--title"),
          let state = WorkspaceEvent.State(rawValue: option("--state") ?? "active") else {
        FileHandle.standardError.write(Data("Usage: reclaim workspace-event --kind agent|task|file|terminal --id ID --title TITLE [--state active|idle|completed|failed] [--detail TEXT] [--path FILE]\n".utf8))
        exit(2)
    }
    do {
        try WorkspaceEventStore().append(WorkspaceEvent(entityID: entityID, kind: kind, title: title,
            detail: option("--detail") ?? "", state: state, path: option("--path")))
        print("Workspace event recorded locally.")
    } catch {
        FileHandle.standardError.write(Data("Could not record workspace event: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "recipes":
    print("Reclaim recipe catalog — \(RecipeCatalog.all.count) recipes\n")
    for group in Dictionary(grouping: RecipeCatalog.all, by: \.group).sorted(by: { $0.key < $1.key }) {
        print("── \(group.key)")
        for r in group.value {
            print("  \(tierBadge(r.riskTier)) \(r.id) — \(r.displayName)")
        }
    }

case "scan":
    if !wantsJSON {
        FileHandle.standardError.write(Data("Reclaim read-only scan — nothing will be modified.\n".utf8))
    }
    let scanner = StorageScanner()
    var progress: (@Sendable (String) -> Void)? = nil
    if verbose {
        progress = { name in
            FileHandle.standardError.write(Data("  scanning: \(name)\n".utf8))
        }
    }
    let report = scanner.scan(progress: progress)

    if wantsJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        print(String(data: data, encoding: .utf8)!)
        exit(0)
    }

    // ── Header ────────────────────────────────────────────────
    print("")
    print("═══ Reclaim Scan · \(report.hostname) ═══")
    print("Volume: \(ByteFormatter.string(report.volumeFreeBytes)) free of \(ByteFormatter.string(report.volumeTotalBytes))")
    print("Scan took \(String(format: "%.1f", report.elapsedSeconds))s · \(report.findings.count) findings\n")

    // ── Dashboard numbers (section 12: home dashboard panels) ─
    print("  Recoverable now (Green, apps closed):  \(ByteFormatter.string(report.recoverableNowBytes))")
    print("  Review for more (Yellow + Orange):     \(ByteFormatter.string(report.reviewBytes))")
    if report.snapshots.mayPinDeletedBlocks {
        print("  ⧗ \(report.snapshots.count) APFS local snapshot(s) present — freed space may not appear")
        print("    immediately after cleanup; snapshots expire within ~24h.")
    }
    print("")

    // ── Findings by tier ──────────────────────────────────────
    for tier in RiskTier.allCases {
        let items = report.findings.filter { $0.riskTier == tier }
        guard !items.isEmpty else { continue }
        let total = items.reduce(0) { $0 + $1.allocatedBytes }
        print("── \(tierBadge(tier)) \(tier.displayName) · \(ByteFormatter.string(total))")
        for f in items {
            let blocked = f.blockingAppRunning ? "  ⏸ app running — quit before cleanup" : ""
            let skipped = f.skippedProtectedPaths.isEmpty ? "" : "  🔒 \(f.skippedProtectedPaths.count) protected path(s) skipped"
            // Sparse files (Docker.raw, VM disks): apparent size far exceeds
            // real allocation — report the honest number, note the illusion.
            let sparse = f.apparentBytes > f.allocatedBytes * 2
                ? "  ◱ sparse — appears as \(ByteFormatter.string(f.apparentBytes))" : ""
            print(String(format: "  %10@  %@%@%@%@",
                         ByteFormatter.string(f.allocatedBytes) as NSString,
                         f.displayName, blocked, skipped, sparse))
            print("              \(f.path)")
            if verbose {
                print("              \(f.explanation)")
                print("              Impact: \(f.impact)")
            }
        }
        print("")
    }

    if report.findings.isEmpty {
        print("No findings above thresholds. This Mac is clean — or permissions are limiting the scan.")
        print("Tip: grant Full Disk Access to your terminal to scan Messages and app containers.")
    }

case "sweep":
    // Whole-volume attribution sweep: where ALL the bytes are, and how much
    // of the disk the recipe catalog can currently explain.
    var depth = 3
    if let idx = args.firstIndex(of: "--depth"), let d = Int(args[args.index(after: idx)]) {
        depth = d
    }
    if !wantsJSON {
        FileHandle.standardError.write(Data("Reclaim sweep (read-only) — walking \(NSHomeDirectory())…\n".utf8))
    }
    let sweep = VolumeSweep(depth: depth)
    let report = sweep.run(progress: { files in
        FileHandle.standardError.write(Data("  \(files / 1000)k files…\r".utf8))
    })

    if wantsJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(data: try encoder.encode(report), encoding: .utf8)!)
        exit(0)
    }

    print("")
    print("═══ Reclaim Sweep · \(report.root) ═══")
    print("\(ByteFormatter.string(report.totalAllocatedBytes)) allocated · \(report.totalFileCount) files · \(String(format: "%.1f", report.elapsedSeconds))s")
    if report.skippedProtectedCount > 0 {
        print("🔒 \(report.skippedProtectedCount) protected location(s) skipped — macOS said no, and Reclaim listens.")
    }
    let pct = report.totalAllocatedBytes > 0
        ? Double(report.explainedBytes) / Double(report.totalAllocatedBytes) * 100 : 0
    print("Recipe coverage: \(ByteFormatter.string(report.explainedBytes)) explained (\(String(format: "%.0f", pct))%) · \(ByteFormatter.string(report.unexplainedBytes)) unexplained\n")

    let home = NSHomeDirectory()
    for entry in report.entries {
        let rel = entry.path.hasPrefix(home) ? "~" + entry.path.dropFirst(home.count) : entry.path
        let indent = String(repeating: "  ", count: max(0, rel.split(separator: "/").count - 1))
        let tag = entry.explainedBy.map { "  ✓ \($0)" } ?? ""
        print(String(format: "  %10@  %@%@%@",
                     ByteFormatter.string(entry.allocatedBytes) as NSString,
                     indent, rel, tag))
    }
    print("\nDirs ≥ \(ByteFormatter.string(500 * 1024 * 1024)) shown. ✓ = at/below a recipe path; the unexplained rest is recipe-library work to do.")

case "map":
    // "My Mac": a whole-disk breakdown of where space goes, reconciled to the
    // volume's real used bytes. Read-only. Shows everything, not just removable.
    if !wantsJSON {
        FileHandle.standardError.write(Data("Reclaim map (read-only) — measuring your whole Mac…\n".utf8))
    }
    let report = MacStorageMap().run(progress: { files in
        FileHandle.standardError.write(Data("  \(files / 1000)k files…\r".utf8))
    })

    if wantsJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(data: try encoder.encode(report), encoding: .utf8)!)
        exit(0)
    }

    print("")
    print("═══ Reclaim · My Mac · \(report.hostname) ═══")
    print("\(ByteFormatter.string(report.usedBytes)) used of \(ByteFormatter.string(report.capacityBytes)) · \(ByteFormatter.string(report.freeBytes)) free · \(String(format: "%.1f", report.elapsedSeconds))s")
    if report.purgeableBytes > 0 {
        print("Purgeable (OS can reclaim): \(ByteFormatter.string(report.purgeableBytes))")
    }
    print("")
    for c in report.categories {
        let pct = report.usedBytes > 0 ? Double(c.bytes) / Double(report.usedBytes) * 100 : 0
        let tag = c.itemized ? "" : "  (not itemized)"
        print(String(format: "  %10@  %4.0f%%  %@%@",
                     ByteFormatter.string(c.bytes) as NSString, pct, c.name, tag))
    }
    print("")
    print("Categories reconcile to actual used space (\(ByteFormatter.string(report.usedBytes))).")
    if report.overMeasured {
        print("Note: file clones/hardlinks mean categories may overlap — disk total is still exact.")
    }
    if report.fullDiskAccess != .granted {
        print("⚠︎ Full Disk Access is off — Messages, Mail, and protected app data can't be")
        print("  itemized, so they fall into “System & Other.” Grant it in System Settings →")
        print("  Privacy & Security → Full Disk Access for an accurate breakdown.")
    }
    print("Read-only view. Use `reclaim scan` / `reclaim clean` to reclaim space safely.")

case "orphans":
    // Leftover app data whose owning app is no longer installed.
    if !wantsJSON {
        FileHandle.standardError.write(Data("Reclaim orphan scan (read-only) — matching Library data against installed apps…\n".utf8))
    }
    let scanner = OrphanScanner()
    let orphans = scanner.scan()

    if wantsJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(data: try encoder.encode(orphans), encoding: .utf8)!)
        exit(0)
    }

    let likely = orphans.filter { $0.confidence == .likelyOrphan }
    let unattributed = orphans.filter { $0.confidence == .unattributed }
    let likelyTotal = likely.reduce(0) { $0 + $1.allocatedBytes }

    print("")
    print("═══ Reclaim Orphans · leftover app data ═══")
    print("🔵 Likely orphaned (owning app not installed): \(ByteFormatter.string(likelyTotal)) across \(likely.count) item(s)")
    print("These are Blue-tier — reversible via quarantine. Owning app appears gone.\n")

    let home = NSHomeDirectory()
    func row(_ o: Orphan) {
        let rel = o.path.hasPrefix(home) ? "~" + o.path.dropFirst(home.count) : o.path
        let age = o.lastModified.map { "  · last used \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        print(String(format: "  %10@  %@%@", ByteFormatter.string(o.allocatedBytes) as NSString, rel, age))
    }
    for o in likely { row(o) }

    if !unattributed.isEmpty {
        let uTotal = unattributed.reduce(0) { $0 + $1.allocatedBytes }
        print("\n── ❓ Unattributed (couldn't confidently match to an app): \(ByteFormatter.string(uTotal))")
        print("   Review only — NOT called orphaned. Could belong to a shared component.")
        for o in unattributed.prefix(15) { row(o) }
        if unattributed.count > 15 { print("   … and \(unattributed.count - 15) more") }
    }
    if orphans.isEmpty {
        print("No orphaned leftovers found above threshold. Either tidy, or apps live where the inventory didn't look.")
    }
    print("\nSafety: Apple/system components are allowlisted and never flagged.")

case "review":
    // The judgment layer: personal files you might not want anymore.
    if !wantsJSON {
        FileHandle.standardError.write(Data("Reclaim review (read-only) — looking for personal files you may not need…\n".utf8))
    }
    let judge = JudgmentScanner()
    let report = judge.scan()

    if wantsJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(data: try encoder.encode(report), encoding: .utf8)!)
        exit(0)
    }

    func reasonTitle(_ r: SuggestionReason) -> String {
        switch r {
        case .oldAndLarge: "Large & untouched for a while"
        case .veryLarge: "Your biggest files"
        case .duplicate: "Exact duplicates"
        case .oldScreenRecording: "Old screen recordings"
        case .oldScreenshot: "Old screenshots"
        case .installerForInstalledApp: "Installers for apps you already have"
        case .oldDownload: "Old downloads"
        case .oldDeviceBackup: "iPhone/iPad backups"
        case .oldAttachment: "Old attachments"
        }
    }

    let home = NSHomeDirectory()
    let clusterTotal = report.clusters.reduce(0) { $0 + $1.totalBytes }
    print("")
    print("═══ Reclaim Review · personal files you might not need ═══")
    print("We think you could reclaim up to \(ByteFormatter.string(report.totalBytes + clusterTotal)) here.")
    print("Everything below is YOUR content — nothing is ever removed without you choosing it.\n")

    // Clusters first — the "death by a thousand cuts" accumulations.
    if !report.clusters.isEmpty {
        print("▓▓ Accumulations (many small files adding up) ▓▓")
        for c in report.clusters {
            print("── \(c.category) in \(c.directory) · \(ByteFormatter.string(c.totalBytes)) · \(c.count) files")
            print("   \(c.rationale)")
            if verbose, !c.files.isEmpty {
                let names = c.files.prefix(3).map { ($0.path as NSString).lastPathComponent }
                print("   e.g. \(names.joined(separator: ", "))")
            }
        }
        print("")
    }

    for (reason, items) in report.grouped() {
        let total = items.reduce(0) { $0 + $1.sizeBytes }
        print("── \(reasonTitle(reason)) · \(ByteFormatter.string(total)) · \(items.count) item(s)")
        for s in items.prefix(10) {
            let rel = s.path.hasPrefix(home) ? "~" + s.path.dropFirst(home.count) : s.path
            let stars = String(repeating: "●", count: Int((s.confidence * 3).rounded()))
            print(String(format: "  %10@  %@  %@", ByteFormatter.string(s.sizeBytes) as NSString, rel, stars))
            if verbose { print("              \(s.rationale)") }
        }
        if items.count > 10 { print("  … and \(items.count - 10) more") }
        print("")
    }
    if report.suggestions.isEmpty && report.clusters.isEmpty {
        print("Nothing jumped out. Your personal folders look tidy (or are smaller than the thresholds).")
    } else {
        print("● = how confident we are you won't miss it. Run with --verbose to see our reasoning per file.")
    }

case "clean":
    // Quarantine-based cleanup of Green-tier findings. Dry-run by default;
    // --apply actually moves items to the reversible quarantine vault.
    let apply = args.contains("--apply")
    FileHandle.standardError.write(Data("Reclaim clean — scanning for safe (Green) cleanups…\n".utf8))
    let report = StorageScanner().scan()
    let greens = report.findings.filter { $0.riskTier == .green }
    let targets = greens.map {
        CleanupTarget(path: $0.path, riskTier: $0.riskTier, source: $0.recipeID,
                      blockingAppRunning: $0.blockingAppRunning)
    }

    print("")
    if !apply {
        print("═══ Reclaim Clean · DRY RUN ═══")
        print("These Green-tier items would be moved to the reversible quarantine vault:\n")
        var wouldFree: Int64 = 0
        for f in greens {
            if f.blockingAppRunning {
                print("  ⏸ skip  \(f.displayName) — quit the owning app first")
            } else {
                wouldFree += f.allocatedBytes
                print(String(format: "  ✓ %10@  %@", ByteFormatter.string(f.allocatedBytes) as NSString, f.displayName))
            }
        }
        print("\nWould quarantine ~\(ByteFormatter.string(wouldFree)). Nothing has been moved.")
        print("Run `reclaim clean --apply` to do it (reversible via `reclaim restore`).")
        break
    }

    // Apply.
    let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
    let sessionID = df.string(from: Date())
    let ledgerEntry = CleanupExecutor(greenOnly: true).run(targets, sessionID: sessionID)
    try LedgerStore().append(ledgerEntry)

    print("═══ Reclaim Clean · session \(sessionID) ═══")
    let quarantined = ledgerEntry.results.filter { $0.status == .quarantined }
    let skipped = ledgerEntry.results.filter { $0.status != .quarantined }
    for r in quarantined {
        print(String(format: "  ✓ %10@  %@", ByteFormatter.string(r.bytes) as NSString, (r.path as NSString).lastPathComponent))
    }
    for r in skipped {
        print("  ⏸ \(r.status.rawValue): \((r.path as NSString).lastPathComponent) — \(r.detail)")
    }
    print("\nQuarantined \(ByteFormatter.string(ledgerEntry.quarantinedBytes)) · free space \(ledgerEntry.freeDelta >= 0 ? "+" : "")\(ByteFormatter.string(ledgerEntry.freeDelta))")
    if ledgerEntry.freedSpaceLagging {
        print("⧗ Free space hasn't caught up yet — \(ledgerEntry.snapshotsPresent) APFS snapshot(s) are")
        print("  still pinning the freed blocks. Space is released as snapshots expire (~24h).")
    }
    print("Undo anytime: reclaim restore \(sessionID)")

case "quarantine":
    let sessions = Quarantine.sessions()
    print("═══ Reclaim Quarantine ═══")
    if sessions.isEmpty { print("Empty. Nothing has been quarantined."); break }
    for s in sessions {
        let q = Quarantine(sessionID: s)
        let entries = (try? q.manifest()) ?? []
        let total = entries.reduce(0) { $0 + $1.bytes }
        print("  \(s) · \(entries.count) item(s) · \(ByteFormatter.string(total))")
    }
    let lifetime = try LedgerStore().lifetimeQuarantinedBytes
    print("\nLifetime moved to quarantine: \(ByteFormatter.string(lifetime))")
    print("Restore: reclaim restore <session> · Delete permanently: reclaim purge <session> --apply")

case "restore":
    guard let sessionID = args.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
        print("usage: reclaim restore <session-id>"); exit(64)
    }
    let (restored, failed) = try Quarantine(sessionID: sessionID).restoreAll()
    print("Restored \(restored.count) item(s) to their original locations.")
    if !failed.isEmpty {
        print("Could not restore \(failed.count) (missing, or something now exists at the origin):")
        for f in failed { print("  • \(f)") }
    }

case "purge":
    guard let sessionID = args.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
        print("usage: reclaim purge <session-id> --apply"); exit(64)
    }
    if !args.contains("--apply") {
        let q = Quarantine(sessionID: sessionID)
        let total = ((try? q.manifest()) ?? []).reduce(0) { $0 + $1.bytes }
        print("Would PERMANENTLY delete quarantine session \(sessionID) (\(ByteFormatter.string(total))).")
        print("This cannot be undone. Run again with --apply to confirm.")
        break
    }
    try Quarantine(sessionID: sessionID).purge()
    print("Permanently deleted quarantine session \(sessionID).")

default:
    print("""
    usage: reclaim <command> [options]
      scan                 read-only recipe findings
      map                  whole-disk breakdown of where space goes
      sweep [--depth N]    whole-volume attribution + coverage
      orphans              leftover data from uninstalled apps
      review               personal files you might not need
      clean [--apply]      quarantine Green-tier items (dry-run by default)
      quarantine           list quarantined sessions
      restore <session>    undo a cleanup session
      purge <session> --apply   permanently delete quarantined data
      recipes              list the recipe catalog
    options: --json  --verbose
    """)
    exit(64)
}
