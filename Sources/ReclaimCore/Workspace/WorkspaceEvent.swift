import Foundation
import Darwin

public enum WorkspaceKind: String, Codable, CaseIterable, Sendable {
    case app, tab, file, terminal, agent, task, storage
    public var title: String {
        switch self {
        case .app: "Apps"; case .tab: "Browser tabs"; case .file: "Files & edits"
        case .terminal: "Terminals"; case .agent: "Agents"; case .task: "Tasks"; case .storage: "Storage"
        }
    }
    public var symbol: String {
        switch self {
        case .app: "app.fill"; case .tab: "globe"; case .file: "doc.text"
        case .terminal: "terminal"; case .agent: "sparkles"; case .task: "checklist"; case .storage: "internaldrive"
        }
    }
}

/// A report from a local tool, never an inferred action. No screen or keystroke capture.
public struct WorkspaceEvent: Codable, Identifiable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case active, idle, completed, failed }
    public let id: String
    public let entityID: String
    public let kind: WorkspaceKind
    public let title: String
    public let detail: String
    public let state: State
    public let timestamp: Date
    public let path: String?

    public init(id: String = UUID().uuidString, entityID: String, kind: WorkspaceKind,
                title: String, detail: String = "", state: State = .active,
                timestamp: Date = Date(), path: String? = nil) {
        self.id = id; self.entityID = entityID; self.kind = kind; self.title = title
        self.detail = detail; self.state = state; self.timestamp = timestamp; self.path = path
    }

    public var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 256 && !entityID.isEmpty && entityID.utf8.count <= 256 && !title.isEmpty && title.utf8.count <= 512
            && detail.utf8.count <= 2048 && (path?.utf8.count ?? 0) <= 4096
            && !entityID.contains("\n") && !title.contains("\n")
    }

    /// Stable identities collapse heartbeats; old active reports become idle rather than
    /// suggesting an agent is still working. Finished tasks linger briefly for inspection.
    public static func current(_ events: [WorkspaceEvent], now: Date = Date()) -> [WorkspaceEvent] {
        var latest: [String: WorkspaceEvent] = [:]
        for event in events where event.isValid && event.timestamp <= now.addingTimeInterval(5)
            && event.timestamp >= now.addingTimeInterval(-600) {
            let key = event.kind.rawValue + ":" + event.entityID
            if let old = latest[key], old.timestamp > event.timestamp { continue }
            latest[key] = event
        }
        return latest.values.filter {
            ![.completed, .failed].contains($0.state) || now.timeIntervalSince($0.timestamp) < 120
        }.map { event in
            guard event.state == .active, now.timeIntervalSince(event.timestamp) > 60 else { return event }
            return WorkspaceEvent(id: event.id, entityID: event.entityID, kind: event.kind,
                                  title: event.title, detail: event.detail, state: .idle,
                                  timestamp: event.timestamp, path: event.path)
        }.sorted {
            $0.timestamp == $1.timestamp ? $0.entityID < $1.entityID : $0.timestamp > $1.timestamp
        }.prefix(128).map { $0 }
    }
}

/// Bounded local JSONL bridge. Writers lock the same inode, append one complete line,
/// and compact under that lock. A partial/malformed line never breaks the live view.
public struct WorkspaceEventStore: Sendable {
    public let url: URL
    public init(url: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".reclaim/workspace-events.jsonl")) {
        self.url = url
    }
    public func read() -> [WorkspaceEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let offset = size > 262_144 ? size - 262_144 : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if offset > 0 && !lines.isEmpty { lines.removeFirst() }
        // A writer may be mid-append; process only newline-terminated records.
        if data.last != 10 && !lines.isEmpty { lines.removeLast() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return lines.compactMap { try? decoder.decode(WorkspaceEvent.self, from: Data($0)) }.filter(\.isValid)
    }
    public func append(_ event: WorkspaceEvent) throws {
        guard event.isValid else { throw POSIXError(.EINVAL) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let size = try handle.seekToEnd()
        if size > 1_048_576 {
            try handle.seek(toOffset: size - 262_144)
            let tail = try handle.readToEnd() ?? Data()
            let keep = tail.firstIndex(of: 10).map { Data(tail.suffix(from: tail.index(after: $0))) } ?? Data()
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: keep)
        }
        // Separate a previous writer's interrupted record from this complete one.
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1)?.first != 10 {
                try handle.write(contentsOf: Data([10]))
            }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event); data.append(10)
        try handle.write(contentsOf: data)
    }
}
