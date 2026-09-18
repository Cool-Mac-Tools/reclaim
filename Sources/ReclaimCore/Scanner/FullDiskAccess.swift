import Foundation
import Darwin

/// Probe actual reads. `fileExists` can itself return false for a TCC-denied
/// path, and one readable folder does not prove other protected data is open.
public enum FullDiskAccess: Sendable {
    public enum Status: String, Sendable, Codable { case granted, denied, undetermined }

    public static func status() -> Status {
        let home = NSHomeDirectory()
        var outcomes: [Status] = []
        for path in [home + "/Library/Messages", home + "/Library/Mail", home + "/Library/Safari"] {
            if let directory = opendir(path) {
                closedir(directory)
                outcomes.append(.granted)
            } else {
                outcomes.append(errno == EACCES || errno == EPERM ? .denied : .undetermined)
            }
        }
        let fd = open(home + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); outcomes.append(.granted) }
        else if errno == EACCES || errno == EPERM { outcomes.append(.denied) }
        return combine(outcomes)
    }

    static func combine(_ outcomes: [Status]) -> Status {
        if outcomes.contains(.denied) { return .denied }
        return outcomes.contains(.granted) ? .granted : .undetermined
    }
    public static var isGranted: Bool { status() == .granted }
}
