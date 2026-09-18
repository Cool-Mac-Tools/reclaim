import Testing
import Foundation
@testable import ReclaimCore

@Suite struct ReliabilityTests {
    private func temporaryHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reclaim-reliability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func entry(_ id: String) -> CleanupLedgerEntry {
        CleanupLedgerEntry(sessionID: id, startedAt: Date(), results: [], freeBeforeBytes: 0, freeAfterBytes: 0, snapshotsPresent: 0)
    }

    @Test func corruptCleanupHistoryCannotBecomeEmptyOrBeOverwritten() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let store = LedgerStore(home: home.path)
        try store.append(entry("first"))
        let url = URL(fileURLWithPath: store.path)
        try Data("truncated {".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.all() }
        #expect(throws: (any Error).self) { try store.append(entry("second")) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "truncated {")
    }
    @Test func concurrentHistoryWritesPreserveEverySessionAndDeduplicateRetries() async throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let store = LedgerStore(home: home.path)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { try store.append(entry("session-\(i)")) }
            }
            try await group.waitForAll()
        }
        try store.append(entry("session-0"))
        #expect(try store.all().count == 20)
        let backup = try DurableJSONStore<[CleanupLedgerEntry]>(path: store.path + ".backup").read(default: [])
        #expect(backup.count == 20)
    }
    @Test func missingHistoryIsEmptyButAReadFailureIsNot() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let store = LedgerStore(home: home.path)
        #expect(try store.all().isEmpty)
        try FileManager.default.createDirectory(atPath: store.path, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.all() }
    }
    @Test func messagesBackgroundServicesDoNotMeanMessagesIsOpen() {
        #expect(!AppProcessMatcher.matches("/System/Library/PrivateFrameworks/MessagesBlastDoorService", appName: "Messages"))
        #expect(!AppProcessMatcher.matches("/tmp/Messages/report", appName: "Messages"))
        #expect(AppProcessMatcher.matches("/System/Applications/Messages.app/Contents/MacOS/Messages", appName: "Messages"))
        #expect(AppProcessMatcher.matches("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", appName: "Google Chrome"))
        #expect(!AppProcessMatcher.matches("/Applications/Mail.app/Contents/MacOS/Mail", appName: "Messages"))
    }
    @Test func discoveryFindsUnityInVendorFoldersWithoutTreatingHelpersAsApps() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Applications")
        let unity = root.appendingPathComponent("Unity/Hub/Editor/6000.1/Unity.app")
        let helper = unity.appendingPathComponent("Contents/Helpers/Unity Helper.app")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        let paths = AppDiscovery.paths(roots: [root.path])
        #expect(paths == [unity.path])
        #expect(AppDiscovery.isUserApplication(unity.path, home: home.path))
        #expect(!AppDiscovery.isUserApplication(helper.path, home: home.path))
    }
    @Test func observedUsageSurvivesRelaunchAndUnknownUsageStaysUnknown() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try AppUsageStore(home: home.path).record(paths: ["/Applications/Cursor.app"], at: now)
        let used = try AppUsageStore(home: home.path).all()["/Applications/Cursor.app"]
        #expect(used == now)
        #expect(!UnusedAppScanner.isUnused(lastUsed: used, installedAt: .distantPast, now: now, unusedDays: 180))
        #expect(!UnusedAppScanner.isUnused(lastUsed: nil, installedAt: .distantPast, now: now, unusedDays: 180))
        let unknown = UnusedApp(path: "x", name: "App", bytes: 1, lastUsed: nil, installedAt: .distantPast)
        #expect(unknown.subtitle().contains("unknown"))
        #expect(unknown.rationale().contains("no reliable"))
    }
    @Test func appInternalsAndEntireAttachmentCollectionsAreRefused() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let internalFile = home.appendingPathComponent("Applications/Keep.app/Contents/MacOS/run")
        try FileManager.default.createDirectory(at: internalFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("do not move".utf8).write(to: internalFile)
        let attachments = home.appendingPathComponent("Library/Messages/Attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let targets = [internalFile.path, attachments.path].map { CleanupTarget(path: $0, riskTier: .orange, source: "my-mac") }
        let result = CleanupExecutor(home: home.path, greenOnly: false).run(targets, sessionID: "test")
        #expect(result.results.allSatisfy { $0.status == .skippedNotAllowed })
        #expect(FileManager.default.fileExists(atPath: internalFile.path))
    }
    @Test func processGroupsIncludeHelpersAndEveryBackgroundProcessExactlyOnce() {
        let processes: [RunningProcess] = [
            .init(pid: 1, name: "Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", cpuPercent: 10, memoryBytes: 100),
            .init(pid: 2, name: "Helper", path: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", cpuPercent: 20, memoryBytes: 200),
            .init(pid: 3, name: "node", path: "/opt/homebrew/bin/node", cpuPercent: 30, memoryBytes: 300)
        ]
        let groups = ActivityProcessGroup.groups(processes)
        #expect(groups.count == 2)
        #expect(groups.flatMap(\.processes).count == processes.count)
        #expect(groups.reduce(0) { $0 + $1.memoryBytes } == 600)
        #expect(groups.first { $0.appPath != nil }?.cpuPercent == 30)
    }
    @Test func partialAccessMustNotClaimFullAccess() {
        #expect(FullDiskAccess.combine([.granted, .denied]) == .denied)
        #expect(FullDiskAccess.combine([.undetermined]) == .undetermined)
        #expect(FullDiskAccess.combine([.granted, .undetermined]) == .granted)
    }
    @Test func unreadableOrMissingBrowsePathIsNotAnEmptyFolder() {
        let result = DirLister.inspectFiles(of: "/nonexistent-\(UUID().uuidString)")
        #expect(result.files.isEmpty)
        #expect(result.blockedPaths.count == 1)
    }
    @Test func recoveredSpaceCannotIncludeUnrelatedBackgroundDeletion() {
        let entry = PurgeLedgerEntry(succeeded: ["a"], failed: [], deletedBytes: 100, freeBeforeBytes: 100, freeAfterBytes: 10_000)
        #expect(entry.verifiedFreedBytes == 100)
    }
}

@Suite struct ApplicationRemovalTests {
    @Test func wholeUserAppIsSelectableButItsFilesAndAppleAppsAreNot() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Applications/Unity/Editor/Unity.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Unity")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: executable)
        #expect(CleanupExecutor.isRemovable(app.path, home: home.path))
        #expect(!CleanupExecutor.isRemovable(executable.path, home: home.path))
        #expect(!AppDiscovery.isUserApplication("/System/Applications/Messages.app", home: home.path))
        #expect(!AppDiscovery.isUserApplication("/Applications/Reclaim.app", home: home.path))
        #expect(MacStorageMap.atomicBundleRoot("/Applications/Example.APP/Contents/MacOS/run") == "/Applications/Example.APP")
    }
}

@Suite struct HistoryCompatibilityTests {
    @Test func originalRecoveryHistoryStillDecodesAfterAddingToolCleanups() throws {
        let json = #"[{"id":"old","date":"2026-09-17T12:00:00Z","succeeded":["one"],"failed":[],"deletedBytes":500,"freeBeforeBytes":100,"freeAfterBytes":400}]"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([PurgeLedgerEntry].self, from: Data(json.utf8))
        #expect(entries.first?.operation == nil)
        #expect(entries.first?.verifiedFreedBytes == 300)
    }
}
