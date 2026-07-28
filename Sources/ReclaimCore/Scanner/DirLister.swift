import Foundation

/// One entry when drilling into a folder: a child file or subfolder with its
/// allocated size. Powers the expand-and-delete-parts tree in the UI.
public struct FileNode: Identifiable, Sendable, Hashable {
    public let path: String
    public let bytes: Int64
    public let isDirectory: Bool
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, bytes: Int64, isDirectory: Bool) {
        self.path = path
        self.bytes = bytes
        self.isDirectory = isDirectory
    }
}

/// Lists the immediate contents of a directory with per-entry allocated sizes,
/// largest first. On-demand (called when the user expands a row) and capped so
/// a huge folder can't stall the UI. Read-only.
public enum DirLister {
    public static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func children(of dir: String, limit: Int = 300) -> [FileNode] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var nodes: [FileNode] = []
        nodes.reserveCapacity(names.count)
        for name in names {
            let path = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            let bytes = SizeMeasurement.measure(path).allocatedBytes
            nodes.append(FileNode(path: path, bytes: bytes, isDirectory: isDir.boolValue))
        }
        nodes.sort { $0.bytes > $1.bytes }
        return Array(nodes.prefix(limit))
    }
}
