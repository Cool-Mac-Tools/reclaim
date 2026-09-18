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
        inspectFiles(of: dir, limit: limit, minBytes: minBytes).files
    }

    public struct Listing: Sendable {
        public let files: [ClusterFile]
        public let blockedPaths: [String]
        public let matchingCount: Int
    }

    public static func inspectFiles(of dir: String, limit: Int = 1500,
                                    minBytes: Int64 = 16 * 1024) -> Listing {
        let url = URL(fileURLWithPath: dir)
        do { _ = try FileManager.default.contentsOfDirectory(atPath: dir) }
        catch { return Listing(files: [], blockedPaths: [dir], matchingCount: 0) }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                       .isRegularFileKey, .contentModificationDateKey]
        var blocked: [String] = []
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants], errorHandler: { url, _ in
                if blocked.count < 20 { blocked.append(url.path) }; return true
            }) else { return Listing(files: [], blockedPaths: [dir], matchingCount: 0) }
        var files: [ClusterFile] = []
        var count = 0
        while let u = en.nextObject() as? URL {
            if MacStorageMap.isAtomicBundle(u.path) { en.skipDescendants(); continue }
            guard !MacStorageMap.insideAtomicBundle(u.path) else { continue }
            do {
                let v = try u.resourceValues(forKeys: keys)
                guard v.isRegularFile == true else { continue }
                let bytes = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                guard bytes >= minBytes else { continue }
                count += 1
                files.append(ClusterFile(path: u.path, bytes: bytes, modified: v.contentModificationDate))
                if files.count > max(1, limit) * 4 {
                    files = Array(files.sorted { $0.bytes > $1.bytes }.prefix(max(1, limit)))
                }
            } catch { if blocked.count < 20 { blocked.append(u.path) } }
        }
        return Listing(files: Array(files.sorted { $0.bytes > $1.bytes }.prefix(max(1, limit))),
                       blockedPaths: blocked, matchingCount: count)
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
