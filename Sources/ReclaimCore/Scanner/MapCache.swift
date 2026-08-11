import Foundation

/// Persists the last whole-disk "My Mac" map so the tab opens instantly with the
/// previous picture (marked with its age) instead of forcing a fresh full-volume
/// walk every launch. The map is advisory context, never an action source — a
/// cleanup always re-measures live — so a slightly stale cached view is safe.
public enum MapCache {
    private static var url: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".reclaim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lastmap.json")
    }

    public static func save(_ report: MacStorageReport) {
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func load() -> MacStorageReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MacStorageReport.self, from: data)
    }

    public static func clear() { try? FileManager.default.removeItem(at: url) }
}
