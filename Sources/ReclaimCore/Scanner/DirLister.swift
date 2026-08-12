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

    /// The largest actual FILES anywhere inside a directory, flattened — so a
    /// folder full of opaque plumbing (e.g. Messages' `XX/YY/<UUID>/photo.heic`)
    /// surfaces the real photos/videos/documents, not the meaningless
    /// intermediate folders. Recursive, capped, and off the main thread.
    public static func deepFiles(of dir: String, limit: Int = 500,
                                 minBytes: Int64 = 16 * 1024) -> [ClusterFile] {
        let url = URL(fileURLWithPath: dir)
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .isRegularFileKey, .contentModificationDateKey,
        ]
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return [] }

        var files: [ClusterFile] = []
        let trimAt = limit * 4
        while let u = en.nextObject() as? URL {
            guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            let bytes = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            guard bytes >= minBytes else { continue }
            files.append(ClusterFile(path: u.path, bytes: bytes, modified: v.contentModificationDate))
            if files.count > trimAt {
                files.sort { $0.bytes > $1.bytes }
                files = Array(files.prefix(limit))
            }
        }
        files.sort { $0.bytes > $1.bytes }
        return Array(files.prefix(limit))
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
