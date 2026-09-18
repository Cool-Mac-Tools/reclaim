import Foundation

/// Every sampled process appears exactly once. App helpers are folded into
/// their outer application bundle; other executables remain visible by path.
public struct ActivityProcessGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let appPath: String?
    public let processes: [RunningProcess]
    public var cpuPercent: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    public var memoryBytes: Int64 { processes.reduce(0) { $0 + $1.memoryBytes } }

    public static func groups(_ processes: [RunningProcess]) -> [ActivityProcessGroup] {
        let grouped = Dictionary(grouping: processes) { process in
            let path = AppDiscovery.canonicalPath(process.path)
            if let range = path.range(of: ".app/", options: .caseInsensitive) {
                return String(path[..<range.lowerBound]) + ".app"
            }
            return path
        }
        return grouped.map { path, processes in
            let app = path.lowercased().hasSuffix(".app")
            return ActivityProcessGroup(id: path,
                name: app ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent : URL(fileURLWithPath: path).lastPathComponent,
                appPath: app ? path : nil, processes: processes.sorted { $0.pid < $1.pid })
        }.sorted { $0.id < $1.id }
    }
}
