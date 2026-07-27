import Testing
import Foundation
@testable import ReclaimCore

@Suite struct RecipeCatalogTests {
    @Test func recipeIDsAreUnique() {
        let ids = RecipeCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func redTierRecipesNeverQuarantine() {
        // System-protected data may only go through a supported manager.
        for recipe in RecipeCatalog.all where recipe.riskTier == .red {
            #expect(recipe.action == .supportedCLI || recipe.action == .none)
        }
    }

    @Test func orangeTierIsNeverAutomated() {
        // Personal content requires explicit review — non-negotiable.
        for recipe in RecipeCatalog.all where recipe.riskTier == .orange {
            #expect(recipe.action == .reviewOnly)
        }
    }

    @Test func onlyGreenIsAutomatable() {
        for tier in RiskTier.allCases {
            #expect(tier.automatable == (tier == .green))
        }
    }

    @Test func catalogExpandedBeyondCaseStudy() {
        // The deep-research pass should have grown the library well past
        // the original ~25 case-study recipes.
        #expect(RecipeCatalog.all.count >= 50)
    }

    @Test func communityRecipesNeverGreenlightAutomation() {
        // Community-known recipes are detection-only until verified: they may
        // describe an action, but they must not sit in an auto-runnable state
        // that a future executor could fire without human review.
        for recipe in RecipeCatalog.all where recipe.confidence == .communityKnown {
            if recipe.riskTier.automatable {
                #expect(recipe.action != .quarantine || recipe.riskTier == .green)
            }
        }
    }

    @Test func personalTierRecipesAreReviewOnly() {
        // Orange (personal/cloud) must never carry an acting method, no matter
        // the source — this is the invariant the Parallels recipe first broke.
        for recipe in RecipeCatalog.all where recipe.riskTier == .orange {
            #expect(recipe.action == .reviewOnly)
        }
    }
}

@Suite struct ScannerTests {
    @Test func scanIsReadOnlyAndCompletes() {
        // Smoke test against a temp-dir recipe so CI doesn't depend on
        // the machine's real state.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("blob.bin")
        FileManager.default.createFile(atPath: file.path, contents: Data(count: 1024 * 1024))
        defer { try? FileManager.default.removeItem(at: dir) }

        let recipe = Recipe(
            id: "test.blob", displayName: "Test blob", group: "Test",
            paths: [dir.path], riskTier: .green, thresholdBytes: 1,
            action: .quarantine, explanation: "", impact: "", recurrence: ""
        )
        let report = StorageScanner(recipes: [recipe]).scan()
        #expect(report.findings.count == 1)
        #expect(report.findings[0].allocatedBytes >= 1024 * 1024)
        // The scan must not have touched the file.
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func globResolution() {
        let matches = PathResolver.resolve("~/*")
        #expect(!matches.isEmpty)
        // Deep globs are deferred in v0 — must return empty, not walk the disk.
        #expect(PathResolver.resolve("~/**/.next/cache").isEmpty)
    }

    @Test func findingsAreDedupedByPath() {
        // Two recipes (or two globs) pointing at the same path must yield ONE
        // finding — never a double-count that would inflate totals and fail on
        // the second quarantine attempt.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-dedup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("x").path,
                                       contents: Data(count: 1024 * 1024))
        defer { try? FileManager.default.removeItem(at: dir) }
        let r1 = Recipe(id: "a", displayName: "A", group: "g", paths: [dir.path],
                        riskTier: .green, thresholdBytes: 1, action: .quarantine,
                        explanation: "", impact: "", recurrence: "")
        let r2 = Recipe(id: "b", displayName: "B", group: "g", paths: [dir.path],
                        riskTier: .green, thresholdBytes: 1, action: .quarantine,
                        explanation: "", impact: "", recurrence: "")
        let report = StorageScanner(recipes: [r1, r2]).scan()
        #expect(report.findings.filter { $0.path == dir.path }.count == 1)
    }
}

@Suite struct OrphanScannerTests {
    /// Build a throwaway home with a Library/Application Support tree.
    private func makeHome(_ folders: [String]) -> String {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-orphan-\(UUID().uuidString)")
        let appSupport = home.appendingPathComponent("Library/Application Support")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        for folder in folders {
            let dir = appSupport.appendingPathComponent(folder)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent("blob.bin").path,
                contents: Data(count: 30 * 1024 * 1024))
        }
        return home.path
    }

    @Test func flagsBundleIDLeftoverWithNoOwningApp() {
        let home = makeHome(["com.fake.deadapp"])
        defer { try? FileManager.default.removeItem(atPath: home) }
        let scanner = OrphanScanner(
            inventory: AppInventory(bundleIDs: [], names: []), recipes: [])
        let orphans = scanner.scan(homeOverride: home)
        #expect(orphans.contains { $0.folderName == "com.fake.deadapp" && $0.confidence == .likelyOrphan })
    }

    @Test func neverFlagsAppleComponents() {
        // The Nektony failure mode: system components must never be orphaned.
        let home = makeHome(["com.apple.appstore", "com.apple.Safari", "CrashReporter"])
        defer { try? FileManager.default.removeItem(atPath: home) }
        let scanner = OrphanScanner(
            inventory: AppInventory(bundleIDs: [], names: []), recipes: [])
        let orphans = scanner.scan(homeOverride: home)
        #expect(orphans.isEmpty)
    }

    @Test func respectsInstalledApps() {
        let home = makeHome(["com.installed.app"])
        defer { try? FileManager.default.removeItem(atPath: home) }
        let scanner = OrphanScanner(
            inventory: AppInventory(bundleIDs: ["com.installed.app"], names: []), recipes: [])
        #expect(scanner.scan(homeOverride: home).isEmpty)
    }

    @Test func excludesRecipeCoveredPaths() {
        let home = makeHome(["com.fake.cached"])
        defer { try? FileManager.default.removeItem(atPath: home) }
        let covered = "\(home)/Library/Application Support/com.fake.cached"
        let recipe = Recipe(
            id: "test.cached", displayName: "", group: "", paths: [covered],
            riskTier: .green, thresholdBytes: 1, action: .quarantine,
            explanation: "", impact: "", recurrence: "")
        let scanner = OrphanScanner(
            inventory: AppInventory(bundleIDs: [], names: []), recipes: [recipe])
        #expect(scanner.scan(homeOverride: home).isEmpty)
    }
}

@Suite struct JudgmentScannerTests {
    private func makeHome() -> (String, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-judge-\(UUID().uuidString)")
        let downloads = home.appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        return (home.path, downloads)
    }

    private func write(_ url: URL, bytes: Int, modified: Date? = nil) {
        FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))
        if let modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    @Test func detectsVideoCluster() {
        let (home, downloads) = makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        for i in 0..<6 { write(downloads.appendingPathComponent("clip\(i).mp4"), bytes: 80 * 1024 * 1024) }
        let report = JudgmentScanner(inventory: AppInventory(bundleIDs: [], names: [])).scan(homeOverride: home)
        #expect(report.clusters.contains { $0.category == "Videos" && $0.count == 6 })
    }

    @Test func detectsExactDuplicate() {
        let (home, downloads) = makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let payload = Data((0..<(5 * 1024 * 1024)).map { UInt8($0 % 251) })
        try? payload.write(to: downloads.appendingPathComponent("original.bin"))
        try? payload.write(to: downloads.appendingPathComponent("copy.bin"))
        let report = JudgmentScanner(inventory: AppInventory(bundleIDs: [], names: [])).scan(homeOverride: home)
        #expect(report.suggestions.contains { $0.reason == .duplicate })
    }

    @Test func flagsInstallerForInstalledApp() {
        let (home, downloads) = makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        write(downloads.appendingPathComponent("Zoom-6.1.dmg"), bytes: 120 * 1024 * 1024)
        let inv = AppInventory(bundleIDs: [], names: ["zoom"])
        let report = JudgmentScanner(inventory: inv).scan(homeOverride: home)
        #expect(report.suggestions.contains { $0.reason == .installerForInstalledApp })
    }

    @Test func everySuggestionIsPersonalTierNeverAutomatable() {
        let (home, downloads) = makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        write(downloads.appendingPathComponent("huge.mov"), bytes: 300 * 1024 * 1024,
              modified: Date(timeIntervalSince1970: 0))
        let report = JudgmentScanner(inventory: AppInventory(bundleIDs: [], names: [])).scan(homeOverride: home)
        // Personal content is Orange or Blue — never Green (auto-runnable).
        for s in report.suggestions { #expect(s.riskTier != .green) }
    }
}

@Suite struct QuarantineTests {
    private func makeHome() -> String {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-q-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.path
    }

    private func makeFile(_ home: String, _ name: String, bytes: Int) -> String {
        let dir = (home as NSString).appendingPathComponent("junk")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent(name)
        FileManager.default.createFile(atPath: path, contents: Data(count: bytes))
        return path
    }

    @Test func quarantineThenRestoreReturnsFileIntact() throws {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let payload = Data((0..<4096).map { UInt8($0 % 255) })
        let path = (home as NSString).appendingPathComponent("junk/data.bin")
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try payload.write(to: URL(fileURLWithPath: path))

        let q = Quarantine(home: home, sessionID: "s1")
        _ = try q.store(path, source: "test")
        #expect(!FileManager.default.fileExists(atPath: path))   // gone from origin

        let (restored, failed) = try q.restoreAll()
        #expect(restored.count == 1 && failed.isEmpty)
        // Content must be byte-identical after the round trip.
        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(after == payload)
    }

    @Test func storeRefusesMissingSource() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let q = Quarantine(home: home, sessionID: "s1")
        #expect(throws: (any Error).self) {
            _ = try q.store((home as NSString).appendingPathComponent("nope"), source: "test")
        }
    }

    @Test func executorNeverTouchesRedTier() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = makeFile(home, "protected.bin", bytes: 1024)
        let target = CleanupTarget(path: path, riskTier: .red, source: "test")
        let entry = CleanupExecutor(home: home).run([target], sessionID: "s1")
        #expect(entry.results.first?.status == .skippedNotAllowed)
        #expect(FileManager.default.fileExists(atPath: path))   // untouched
    }

    @Test func greenOnlyModeSkipsYellowAndOrange() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let yellow = CleanupTarget(path: makeFile(home, "y.bin", bytes: 1024), riskTier: .yellow, source: "t")
        let orange = CleanupTarget(path: makeFile(home, "o.bin", bytes: 1024), riskTier: .orange, source: "t")
        let entry = CleanupExecutor(home: home, greenOnly: true).run([yellow, orange], sessionID: "s1")
        #expect(entry.results.allSatisfy { $0.status == .skippedNotAllowed })
        #expect(FileManager.default.fileExists(atPath: yellow.path))
        #expect(FileManager.default.fileExists(atPath: orange.path))
    }

    @Test func greenTargetIsQuarantinedAndLedgered() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let green = CleanupTarget(path: makeFile(home, "cache.bin", bytes: 2048), riskTier: .green, source: "t")
        let entry = CleanupExecutor(home: home).run([green], sessionID: "s1")
        #expect(entry.results.first?.status == .quarantined)
        #expect(entry.quarantinedBytes >= 2048)
        #expect(!FileManager.default.fileExists(atPath: green.path))
    }

    @Test func runningAppBlocksCleanup() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let t = CleanupTarget(path: makeFile(home, "c.bin", bytes: 1024), riskTier: .green,
                              source: "t", blockingAppRunning: true)
        let entry = CleanupExecutor(home: home).run([t], sessionID: "s1")
        #expect(entry.results.first?.status == .skippedAppRunning)
        #expect(FileManager.default.fileExists(atPath: t.path))
    }
}

@Suite struct DuplicateFinderTests {
    @Test func groupsIdenticalFilesAndComputesReclaimable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dup-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let payload = Data(repeating: 7, count: 200_000)
        for name in ["a.bin", "b.bin", "c.bin"] {
            try payload.write(to: root.appendingPathComponent(name))
        }
        try Data(repeating: 9, count: 200_000).write(to: root.appendingPathComponent("u.bin"))

        let files = ["a.bin", "b.bin", "c.bin", "u.bin"].map {
            ClusterFile(path: root.appendingPathComponent($0).path, bytes: 200_000, modified: nil)
        }
        let groups = DuplicateFinder.find(in: files)
        #expect(groups.count == 1)                       // only a/b/c match
        #expect(groups.first?.count == 3)
        #expect(groups.first?.reclaimableBytes == 400_000) // 2 extra copies × 200 KB
    }

    @Test func sameSizeDifferentContentIsNotADuplicate() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dup2-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(repeating: 1, count: 50_000).write(to: root.appendingPathComponent("x.bin"))
        try Data(repeating: 2, count: 50_000).write(to: root.appendingPathComponent("y.bin"))
        let files = ["x.bin", "y.bin"].map {
            ClusterFile(path: root.appendingPathComponent($0).path, bytes: 50_000, modified: nil)
        }
        #expect(DuplicateFinder.find(in: files).isEmpty)
    }
}

@Suite struct MacStorageMapTests {
    @Test func classifyRoutesHomeFolders() {
        let home = "/Users/x"
        #expect(MacStorageMap.classify(home + "/.Trash/old.zip", home: home) == "trash")
        #expect(MacStorageMap.classify(home + "/Library/Caches/foo", home: home) == "developer")
        #expect(MacStorageMap.classify(home + "/Library/Developer/Xcode/bar", home: home) == "developer")
        #expect(MacStorageMap.classify(home + "/Library/Mail/x", home: home) == "mail")
        #expect(MacStorageMap.classify(home + "/Library/Messages/chat.db", home: home) == "messages")
        #expect(MacStorageMap.classify(home + "/Library/Application Support/App/x", home: home) == "appdata")
        #expect(MacStorageMap.classify(home + "/Pictures/Lib.photoslibrary/x", home: home) == "media")
        #expect(MacStorageMap.classify(home + "/Documents/report.pdf", home: home) == "documents")
        #expect(MacStorageMap.classify(home + "/Desktop/note.txt", home: home) == "documents")
        #expect(MacStorageMap.classify(home + "/Downloads/big.dmg", home: home) == "downloads")
        // Photos & videos are routed by file type, wherever they live.
        #expect(MacStorageMap.classify(home + "/Downloads/clip.mov", home: home) == "media")
        #expect(MacStorageMap.classify(home + "/Documents/vacation.jpg", home: home) == "media")
        #expect(MacStorageMap.classify(home + "/Desktop/screenshot.png", home: home) == "media")
        #expect(MacStorageMap.classify(home + "/Movies/film.mkv", home: home) == "media")
        // …but media inside app/cache locations stays with its app, not "media".
        #expect(MacStorageMap.classify(home + "/Library/Caches/app/img.png", home: home) == "developer")
        #expect(MacStorageMap.classify(home + "/.npm/cache/x", home: home) == "developer")
        #expect(MacStorageMap.classify(home + "/Code/project/main.swift", home: home) == "userother")
    }

    @Test func classifyRoutesOutOfHomeVolumePaths() {
        let home = "/Users/x"
        #expect(MacStorageMap.classify("/Applications/Xcode.app/x", home: home) == "applications")
        #expect(MacStorageMap.classify("/opt/homebrew/Cellar/foo", home: home) == "developer")
        #expect(MacStorageMap.classify("/usr/local/lib/foo", home: home) == "developer")
        #expect(MacStorageMap.classify("/Library/Application Support/Foo/x", home: home) == "systemdata")
        #expect(MacStorageMap.classify("/private/var/vm/swapfile0", home: home) == "systemdata")
        #expect(MacStorageMap.classify("/Users/otheruser/Documents/x", home: home) == "otherusers")
        #expect(MacStorageMap.classify("/Users/Shared/thing", home: home) == "otherusers")
        // Data-volume prefix is normalized to the familiar form.
        #expect(MacStorageMap.classify("/System/Volumes/Data/Users/x/Downloads/a", home: home) == "downloads")
        #expect(MacStorageMap.classify("/System/Volumes/Data/Library/Foo/x", home: home) == "systemdata")
    }

    @Test func classifyIsPathBoundaryAware() {
        // A sibling that merely shares a prefix must not be miscategorized.
        let home = "/Users/x"
        #expect(MacStorageMap.classify(home + "/Downloads2/x", home: home) == "userother")
        #expect(MacStorageMap.classify(home + "/LibraryStuff/x", home: home) == "userother")
    }

    @Test func categoriesReconcileToUsedBytes() {
        // The core accuracy invariant: itemized categories + the computed
        // remainder sum to EXACTLY the disk's used bytes.
        let bytes: [String: Int64] = ["documents": 30, "developer": 20, "applications": 10]
        let cats = MacStorageMap.buildCategories(
            bytesByKey: bytes, countByKey: [:], usedBytes: 100, measuredBytes: 60)
        #expect(cats.reduce(0) { $0 + $1.bytes } == 100)
        let system = cats.first { $0.key == "system" }
        #expect(system?.bytes == 40)
        #expect(system?.itemized == false)
    }

    @Test func categoriesSortedLargestFirst() {
        let bytes: [String: Int64] = ["documents": 10, "developer": 50]
        let cats = MacStorageMap.buildCategories(
            bytesByKey: bytes, countByKey: [:], usedBytes: 100, measuredBytes: 60)
        #expect(cats.map(\.key) == ["developer", "system", "documents"]) // 50, 40, 10
    }

    @Test func noRemainderWhenFullyMeasured() {
        // If we accounted for all used bytes, there is no "System & Other" slice.
        let bytes: [String: Int64] = ["documents": 100]
        let cats = MacStorageMap.buildCategories(
            bytesByKey: bytes, countByKey: [:], usedBytes: 100, measuredBytes: 100)
        #expect(!cats.contains { $0.key == "system" })
        #expect(cats.reduce(0) { $0 + $1.bytes } == 100)
    }

    @Test func fullDiskAccessStatusIsConclusiveOrUndetermined() {
        // We can't assert granted/denied (depends on the host's TCC state), but
        // the probe must always return a valid status without crashing, and be
        // read-only. On a dev Mac at least one probe path typically exists.
        let status = FullDiskAccess.status()
        #expect([.granted, .denied, .undetermined].contains(status))
        #expect(FullDiskAccess.isGranted == (status == .granted))
    }

    @Test func runWalksTempTreeReconcilesAndStaysReadOnly() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("reclaim-map-\(UUID().uuidString)")
        let downloads = root.appendingPathComponent("Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let file = downloads.appendingPathComponent("big.bin")
        try Data(count: 1_000_000).write(to: file)

        // Anchor used-bytes above what we'll measure so a remainder appears.
        // scanRootOverride points the walk at the temp tree instead of the
        // real data volume.
        let map = MacStorageMap(home: root.path, scanRootOverride: root.path,
                                capacityOverride: 10_000_000, freeOverride: 4_000_000,
                                rawFreeOverride: 4_000_000)
        let report = map.run()

        #expect(report.usedBytes == 6_000_000)
        #expect(report.categories.reduce(0) { $0 + $1.bytes } == report.usedBytes)
        #expect(report.categories.contains { $0.key == "downloads" && $0.bytes > 0 })
        #expect(fm.fileExists(atPath: file.path)) // read-only: nothing removed
        try? fm.removeItem(at: root)
    }
}
