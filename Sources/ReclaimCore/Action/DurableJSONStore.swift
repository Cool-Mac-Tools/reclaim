import Foundation
import Darwin

/// Serialize read/modify/write across app and CLI processes. A failed read is
/// never an empty store. Atomic replacement preserves the last complete file;
/// a separate backup keeps the previous valid generation for manual recovery.
struct DurableJSONStore<Value: Codable> {
    let path: String

    func read(default empty: Value) throws -> Value {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Value.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return empty
        }
    }

    func update(default empty: Value, _ change: (inout Value) -> Void) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        var value = try read(default: empty)
        // Only back up a file that decoded successfully. Never overwrite
        // corruption with a fresh, apparently empty history.
        if FileManager.default.fileExists(atPath: path) {
            try Data(contentsOf: url).write(to: URL(fileURLWithPath: path + ".backup"), options: .atomic)
        }
        change(&value)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
