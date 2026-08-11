import Foundation

/// Leftover data whose owning app is no longer installed.
public struct Orphan: Codable, Identifiable, Sendable {
    public var id: String { path }
    public let folderName: String
    public let path: String
    public let allocatedBytes: Int64
    public let lastModified: Date?
    /// Which Library area it was found in ("Application Support", "Caches"…).
    public let area: String
    /// How sure we are this is truly orphaned.
    public let confidence: OrphanConfidence

    public init(folderName: String, path: String, allocatedBytes: Int64,
                lastModified: Date?, area: String, confidence: OrphanConfidence) {
        self.folderName = folderName
        self.path = path
        self.allocatedBytes = allocatedBytes
        self.lastModified = lastModified
        self.area = area
        self.confidence = confidence
    }
}

public enum OrphanConfidence: String, Codable, Sendable {
    /// Bundle-ID-style folder (com.foo.Bar) with no matching installed app.
    /// High confidence it's a genuine leftover.
    case likelyOrphan
    /// Non-bundle-style folder we can't confidently attribute. Surface for
    /// review, don't call it orphaned.
    case unattributed
}

/// Detects app leftovers in the standard Library areas. Blue tier by nature
/// (reversible via quarantine). The safety rule learned from the Nektony
/// failure: NEVER flag Apple/system components — an allowlist is checked
/// first, and only bundle-ID folders with no owning app become orphans.
public struct OrphanScanner: Sendable {
    public let minBytes: Int64
    public let inventory: AppInventory
    /// Absolute paths already explained by a recipe — excluded so `orphans`
    /// surfaces only the coverage gap, never double-reporting known caches.
    let recipePaths: [String]

    public init(minBytes: Int64 = 20 * 1024 * 1024,
                inventory: AppInventory? = nil,
                recipes: [Recipe] = RecipeCatalog.all) {
        self.minBytes = minBytes
        self.inventory = inventory ?? AppInventory.build()
        self.recipePaths = recipes.flatMap { recipe in
            recipe.paths.flatMap { PathResolver.resolve($0) }
        }
    }

    func isRecipeCovered(_ path: String) -> Bool {
        recipePaths.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
    }

    /// (relative Library path, human label) pairs to scan, one level deep.
    static let areas: [(String, String)] = [
        ("Application Support", "Application Support"),
        ("Caches", "Caches"),
        ("Containers", "Containers"),
        ("Logs", "Logs"),
        ("Saved Application State", "Saved Application State"),
        ("HTTPStorages", "HTTPStorages"),
        ("WebKit", "WebKit"),
        ("Preferences", "Preferences"),
    ]

    /// Prefixes that are Apple/system infrastructure or shared scaffolding —
    /// never orphans regardless of installed apps. Guards against the Nektony
    /// class of bug (flagging the App Store, system frameworks, etc.).
    static let allowlistPrefixes = [
        "com.apple.", "apple", "group.com.apple.",
        "crashreporter", "mobiledevice", "mobilesync", "coresimulator",
        "appstore", "app store", "cloudkit", "clouddocs", "icloud",
        "spotlight", "quicklook", "diagnostics", "syncservices",
        "addressbook", "calendaragent", "knowledge", "biome",
        "systempolicy", "tcc", "security", "keychain",
    ]

    func isAllowlisted(_ name: String) -> Bool {
        let lower = name.lowercased()
        return Self.allowlistPrefixes.contains { lower == $0 || lower.hasPrefix($0) }
    }

    public func scan(homeOverride: String? = nil) -> [Orphan] {
        let home = homeOverride ?? NSHomeDirectory()
        let library = (home as NSString).appendingPathComponent("Library")
        var orphans: [Orphan] = []

        for (subdir, label) in Self.areas {
            let areaPath = (library as NSString).appendingPathComponent(subdir)
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: areaPath) else { continue }

            for entry in entries {
                if entry.hasPrefix(".") { continue }
                if isAllowlisted(entry) { continue }

                // Preferences are .plist files; strip the extension to get the
                // owning identifier. Elsewhere entries are folders.
                let bareName = entry.hasSuffix(".plist")
                    ? (entry as NSString).deletingPathExtension : entry
                if isAllowlisted(bareName) { continue }
                if inventory.owns(folderName: bareName) { continue }

                let fullPath = (areaPath as NSString).appendingPathComponent(entry)
                if isRecipeCovered(fullPath) { continue }
                let measured = SizeMeasurement.measure(fullPath)
                guard measured.allocatedBytes >= minBytes else { continue }

                // A dotted, reverse-DNS-looking name with no owner is a
                // confident orphan; anything else is merely unattributed.
                let looksLikeBundleID = bareName.contains(".")
                    && bareName.split(separator: ".").count >= 2
                let confidence: OrphanConfidence = looksLikeBundleID ? .likelyOrphan : .unattributed

                orphans.append(Orphan(
                    folderName: entry,
                    path: fullPath,
                    allocatedBytes: measured.allocatedBytes,
                    lastModified: measured.lastModified,
                    area: label,
                    confidence: confidence
                ))
            }
        }
        return orphans.sorted { $0.allocatedBytes > $1.allocatedBytes }
    }
}
