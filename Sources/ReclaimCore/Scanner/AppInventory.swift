import Foundation

/// A catalog of every app installed on this Mac: bundle IDs and names.
/// Orphan detection is only as safe as this inventory is complete — if an
/// app is installed somewhere we don't look, we must NOT declare its data
/// orphaned. So we err toward "known" and treat inventory gaps conservatively.
public struct AppInventory: Sendable {
    /// Lowercased bundle identifiers of installed apps (com.google.chrome …).
    public let bundleIDs: Set<String>
    /// Lowercased app display names ("google chrome", "cursor" …).
    public let names: Set<String>

    static let searchRoots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "~/Applications",
    ]

    public static func build() -> AppInventory {
        var ids = Set<String>()
        var names = Set<String>()
        let fm = FileManager.default

        for appPath in AppDiscovery.paths(roots: searchRoots.map { NSString(string: $0).expandingTildeInPath }) {
            names.insert(URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent.lowercased())
            let plist = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
            if let data = fm.contents(atPath: plist),
               let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                if let id = info["CFBundleIdentifier"] as? String { ids.insert(id.lowercased()) }
                if let name = info["CFBundleName"] as? String { names.insert(name.lowercased()) }
            }
        }
        return AppInventory(bundleIDs: ids, names: names)
    }

    /// Does a Library subfolder name plausibly belong to an installed app?
    /// Handles both bundle-ID folders (com.foo.Bar) and name folders (Bar).
    public func owns(folderName: String) -> Bool {
        let lower = folderName.lowercased()
        if bundleIDs.contains(lower) { return true }
        if names.contains(lower) { return true }

        // Bundle-ID-style: com.google.Chrome → match if any installed bundle ID
        // shares the reverse-DNS prefix, or the trailing component is a known
        // app name (covers helper folders like com.google.Chrome.helper).
        if lower.contains(".") {
            for id in bundleIDs where id == lower || lower.hasPrefix(id + ".") || id.hasPrefix(lower + ".") {
                return true
            }
            let trailing = lower.split(separator: ".").last.map(String.init) ?? lower
            if names.contains(trailing) { return true }
        } else {
            // Name-style: match against any installed app name as a prefix,
            // so "Cursor" matches "cursor" and "SlackHelper"→"slack" won't
            // (prefix must be the whole name to avoid over-matching).
            if names.contains(lower) { return true }
        }
        return false
    }
}
