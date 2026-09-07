import Foundation
import Testing
@testable import ReclaimCore

@Suite struct WorkspaceTests {
    @Test func heartbeatsReplaceEarlierStateAndExpire() {
        let now = Date(timeIntervalSince1970: 1000)
        let old = WorkspaceEvent(entityID: "build", kind: .task, title: "Build", timestamp: now.addingTimeInterval(-90))
        let done = WorkspaceEvent(entityID: "build", kind: .task, title: "Build", state: .completed, timestamp: now)
        #expect(WorkspaceEvent.current([done, old], now: now).map(\.state) == [.completed])
        #expect(WorkspaceEvent.current([old], now: now).first?.state == .idle)
        #expect(WorkspaceEvent.current([old], now: now.addingTimeInterval(700)).isEmpty)
        #expect(WorkspaceEvent.current([done], now: now.addingTimeInterval(121)).isEmpty)
    }
    @Test func kindIsPartOfIdentityAndFutureEventsAreIgnored() {
        let now = Date()
        let task = WorkspaceEvent(entityID: "same", kind: .task, title: "Task", timestamp: now)
        let agent = WorkspaceEvent(entityID: "same", kind: .agent, title: "Agent", timestamp: now)
        let future = WorkspaceEvent(entityID: "future", kind: .file, title: "Future", timestamp: now.addingTimeInterval(60))
        #expect(WorkspaceEvent.current([task, agent, future], now: now).count == 2)
    }
    @Test func feedSurvivesMalformedAndPartialLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceEventStore(url: root.appendingPathComponent("events.jsonl"))
        try store.append(WorkspaceEvent(entityID: "a", kind: .agent, title: "Agent"))
        let handle = try FileHandle(forWritingTo: store.url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("bad json\n{\"partial\":".utf8)); try handle.close()
        #expect(store.read().map(\.entityID) == ["a"])
        try store.append(WorkspaceEvent(entityID: "b", kind: .task, title: "Build"))
        #expect(store.read().map(\.entityID) == ["a", "b"])
    }
    @Test func invalidEventsAreRefused() {
        let bad = WorkspaceEvent(entityID: "", kind: .task, title: "Build")
        #expect(!bad.isValid)
        #expect(WorkspaceEvent.current([bad]).isEmpty)
    }
    @Test func corruptedManifestRollsBackMove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent(".reclaim/quarantine/test")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let manifest = session.appendingPathComponent("manifest.json")
        try Data("invalid".utf8).write(to: manifest)
        let file = root.appendingPathComponent("keep.txt")
        try Data("keep me".utf8).write(to: file)
        let quarantine = Quarantine(home: root.path, sessionID: "test")
        #expect(throws: (any Error).self) { try quarantine.store(file.path, source: "test") }
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep me")
        #expect(try String(contentsOf: manifest, encoding: .utf8) == "invalid")
    }
    @Test func onlySuccessfulMeasuredPurgesCountAsRecovery() {
        let failed = PurgeLedgerEntry(succeeded: [], failed: ["a"], deletedBytes: 0, freeBeforeBytes: 100, freeAfterBytes: 500)
        let pinned = PurgeLedgerEntry(succeeded: ["a"], failed: [], deletedBytes: 400, freeBeforeBytes: 100, freeAfterBytes: 100)
        let partial = PurgeLedgerEntry(succeeded: ["a"], failed: ["b"], deletedBytes: 400, freeBeforeBytes: 100, freeAfterBytes: 220)
        #expect(failed.verifiedFreedBytes == 0)
        #expect(pinned.verifiedFreedBytes == 0)
        #expect(partial.verifiedFreedBytes == 120)
    }
    @Test func corruptedPurgeLedgerIsNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PurgeLedgerStore(home: root.path)
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: store.url)
        let entry = PurgeLedgerEntry(succeeded: ["test"], failed: [], deletedBytes: 1, freeBeforeBytes: 0, freeAfterBytes: 1)
        #expect(throws: (any Error).self) { try store.append(entry) }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "broken")
    }
}
