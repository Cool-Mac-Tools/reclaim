import Foundation
import CoreServices

/// An installed app the user hasn't opened in a long time — a "you don't use
/// this, might want to delete it" candidate. Personal decision (Orange): never
/// auto-selected, always reversible (the .app moves to quarantine).
public struct UnusedApp: Sendable, Identifiable, Codable {
    public var id: String { path }
    public let path: String        // /Applications/Foo.app
    public let name: String        // "Foo"
    public let bytes: Int64
    public let lastUsed: Date?      // Spotlight's last-opened date, if known
    public let installedAt: Date?   // best-effort install/creation date

    public init(path: String, name: String, bytes: Int64, lastUsed: Date?, installedAt: Date?) {
        self.path = path; self.name = name; self.bytes = bytes
        self.lastUsed = lastUsed; self.installedAt = installedAt
    }

    public var daysSinceUse: Int? { lastUsed.map { Int(Date().timeIntervalSince($0) / 86400) } }
    public var usageUnknown: Bool { lastUsed == nil }

    /// One-line, honest rationale for the row.
    public func rationale(now: Date = Date()) -> String {
        if let last = lastUsed {
            let days = Int(now.timeIntervalSince(last) / 86400)
            return "The latest recorded use was \(days) days ago (\(last.formatted(date: .abbreviated, time: .omitted))). "
                 + "It's taking up \(ByteFormatter.string(bytes)). If you don't need it, removing it is reversible."
        }
        return "macOS has no reliable last-opened date for this app. It uses \(ByteFormatter.string(bytes)). Review it yourself; missing usage data does not mean you never use it."
    }

    /// Short subtitle shown inline on the row.
    public func subtitle(now: Date = Date()) -> String {
        if let last = lastUsed {
            return "Last recorded use \(last.formatted(date: .abbreviated, time: .omitted)) · \(Int(now.timeIntervalSince(last) / 86400)) days ago"
        }
        return "Last opened unknown · large app to review"
    }
}

/// Finds installed apps that haven't been opened in a long time. Read-only:
/// reads size + Spotlight's last-used date, never launches or modifies anything.
public struct UnusedAppScanner: Sendable {
    public struct Config: Sendable {
        /// Not opened in this many days → a candidate.
        public var unusedDays = 180
        /// Skip small helper apps — only surface space worth reclaiming.
        public var minBytes: Int64 = 30 * 1024 * 1024
        public init() {}
    }

    public var config: Config
    public init(config: Config = Config()) { self.config = config }

    /// The pure flagging rule, so it's testable without Spotlight. An app is
    /// "unused" if it was last opened before the cutoff, OR was never opened and
    /// isn't a recent install (so we don't nag about something just downloaded).
    public static func isUnused(lastUsed: Date?, installedAt: Date?, now: Date, unusedDays: Int) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(unusedDays) * 86400)
        if let last = lastUsed { return last < cutoff }
        // Never opened: only flag if it's been sitting installed past the cutoff.
        // Missing metadata is unknown, even for an old installation.
        return false
    }

    /// User-facing app folders only — never /System/Applications (sealed Apple
    /// apps we must not touch).
    static func appDirs(home: String) -> [String] {
        ["/Applications", "/Applications/Utilities",
         (home as NSString).appendingPathComponent("Applications")]
    }

    public func scan(homeOverride: String? = nil, now: Date = Date()) -> [UnusedApp] {
        let home = homeOverride ?? NSHomeDirectory()
        let observed = (try? AppUsageStore(home: home).all()) ?? [:]
        let running = RunningProcessProbe.snapshot()
        var out: [UnusedApp] = []
        for path in AppDiscovery.paths(roots: Self.appDirs(home: home)) {
            guard AppDiscovery.isUserApplication(path, home: home),
                  !AppProcessMatcher.isRunning(appPath: path, executables: running) else { continue }
            let lastUsed = [Self.lastUsedDate(path), observed[path]].compactMap { $0 }.max()
            let installedAt = Self.installDate(path)
            let unused = Self.isUnused(lastUsed: lastUsed, installedAt: installedAt,
                                       now: now, unusedDays: config.unusedDays)
            // Unknown usage can only enter a separate, explicitly labelled
            // large-app review group. Never claim it is unused.
            guard unused || lastUsed == nil else { continue }
            let bytes = SizeMeasurement.measure(path).allocatedBytes
            guard bytes >= (unused ? config.minBytes : max(config.minBytes, 1_000_000_000)) else { continue }
            out.append(UnusedApp(path: path, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                                 bytes: bytes, lastUsed: lastUsed, installedAt: installedAt))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Spotlight's record of when the app was last opened. Nil if never opened
    /// or not indexed.
    static func lastUsedDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        let last = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        let dates = MDItemCopyAttribute(item, "kMDItemUsedDates" as CFString) as? [Date] ?? []
        return (dates + [last].compactMap { $0 }).filter { $0 >= Date(timeIntervalSince1970: 978307200) && $0 <= Date() }.max()
    }

    /// Best-effort install date: the bundle's creation date (falls back to
    /// modification date).
    static func installDate(_ path: String) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)
    }
}
