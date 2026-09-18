import Foundation

public enum AppDiscovery {
    /// Walk nested vendor folders (including Unity Hub versions), but never
    /// descend into an app, framework, symlink or another package.
    public static func paths(roots: [String]) -> [String] {
        var found = Set<String>()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        for root in roots {
            guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            while let url = walk.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true { walk.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "app" {
                    found.insert(url.standardizedFileURL.path)
                    walk.skipDescendants()
                } else if values.isPackage == true || walk.level > 8 {
                    walk.skipDescendants()
                }
            }
        }
        return found.sorted()
    }

    public static func userRoots(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", home + "/Applications"]
    }

    public static func isUserApplication(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let path = canonicalPath(path)
        guard path.lowercased().hasSuffix(".app"), !MacStorageMap.insideAtomicBundle(path),
              userRoots(home: home).contains(where: { path.hasPrefix($0 + "/") }),
              Bundle(path: path)?.bundleIdentifier != "com.reclaimac.app",
              URL(fileURLWithPath: path).lastPathComponent != "Reclaim.app" else { return false }
        return true
    }

    public static func canonicalPath(_ path: String) -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = "/System/Volumes/Data"
        return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path
    }
}

/// Locally observed launches/activations supplement Spotlight. Missing records
/// remain unknown; a timestamp proves use, never non-use.
public struct AppUsageStore: Sendable {
    public let path: String
    public init(home: String = NSHomeDirectory()) { path = home + "/.reclaim/app-usage.json" }
    public func all() throws -> [String: Date] {
        try DurableJSONStore<[String: Date]>(path: path).read(default: [:])
    }
    public func record(paths: [String], at date: Date = Date()) throws {
        try DurableJSONStore<[String: Date]>(path: path).update(default: [:]) { values in
            for path in paths { values[AppDiscovery.canonicalPath(path)] = date }
        }
    }
}

public enum AppProcessMatcher {
    /// Match the application bundle or exact executable, never an arbitrary
    /// substring such as MessagesBlastDoorService or a folder named Messages.
    public static func matches(_ executable: String, appName: String) -> Bool {
        let parts = executable.lowercased().split(separator: "/").map(String.init)
        let name = appName.lowercased()
        if let firstApp = parts.first(where: { $0.hasSuffix(".app") }) {
            return firstApp == name + ".app"
        }
        return parts.last == name
    }

    public static func running(_ names: [String], executables: Set<String>) -> [String] {
        names.filter { name in executables.contains { matches($0, appName: name) } }
    }

    public static func isRunning(appPath: String, executables: Set<String>) -> Bool {
        let path = AppDiscovery.canonicalPath(appPath).lowercased()
        return executables.contains { AppDiscovery.canonicalPath($0).lowercased().hasPrefix(path + "/") }
    }
}
