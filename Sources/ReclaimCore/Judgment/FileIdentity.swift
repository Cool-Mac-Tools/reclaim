import Foundation
import Darwin

/// Guards that keep duplicate cleanup honest. Two failure modes we must never
/// walk a user into:
///   • Deleting a **hardlink** — another name for the same inode. Removing it
///     frees no space at all, so offering it as "reclaim X GB" is a lie.
///   • Deleting a **cloud-synced** copy — a local delete under iCloud Drive,
///     Dropbox, Google Drive, or OneDrive can propagate to the cloud and to
///     every other device. That's data loss, not cleanup.
enum FileIdentity {
    /// A stable (device, inode) key. Two paths that share a key are the SAME
    /// underlying file (a hardlink); deleting one keeps the data and frees
    /// nothing. `lstat` so a symlink is judged on its own identity, not its
    /// target's.
    static func inodeKey(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino)"
    }

    /// Path fragments that mark a cloud-provider-managed location. Any file
    /// under one is excluded from duplicate cleanup.
    static let cloudMarkers = [
        "/Library/Mobile Documents/",   // iCloud Drive
        "/Library/CloudStorage/",       // Dropbox/Drive/OneDrive via File Provider
        "/Dropbox/",
        "/Google Drive/", "/GoogleDrive/", "/My Drive/",
        "/OneDrive", "/pCloud", "/Sync.com/",
    ]

    static func isCloudSynced(_ path: String) -> Bool {
        cloudMarkers.contains { path.contains($0) }
    }
}
