import Foundation

/// System probes must never leave a live view or cleanup verification waiting
/// indefinitely on an OS utility. No shell or user-supplied command strings.
enum ReadOnlyCommand {
    static func output(_ executable: String, arguments: [String], timeout: TimeInterval = 2) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let expiry = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: expiry)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit(); expiry.cancel()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
