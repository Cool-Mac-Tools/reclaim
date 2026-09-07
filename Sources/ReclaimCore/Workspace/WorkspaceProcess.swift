import Foundation

/// Recognizes executable names, not command arguments or guessed agent actions.
public enum WorkspaceProcess {
    public static func kind(executable: String) -> WorkspaceKind? {
        let name = (executable as NSString).lastPathComponent.lowercased()
        if ["codex", "claude", "cursor-agent", "aider", "opencode"].contains(name) { return .agent }
        if ["xcodebuild", "swift", "swiftc", "swift-frontend", "clang", "clang++", "make", "cmake", "ninja", "pytest", "cargo", "rustc", "go"].contains(name) { return .task }
        return nil
    }
}
