import Foundation

/// Cleanup via a tool's own supported command (`npm cache clean`, `brew
/// cleanup`, …) — the method the master plan prefers over raw file removal for
/// tool-managed caches (the simctl-vs-`rm` lesson). Unlike quarantine these are
/// NOT reversible by Reclaim: the tool performs its own safe cleanup. The UI
/// confirms each explicitly and shows the exact command.
public enum SupportedCLI {
    public struct Command: Codable, Sendable, Identifiable {
        public var id: String { recipeID }
        public let recipeID: String
        public let tool: String        // binary to locate, e.g. "brew"
        public let invocation: String  // full shell command
        public let label: String       // human description

        public init(recipeID: String, tool: String, invocation: String, label: String) {
            self.recipeID = recipeID; self.tool = tool
            self.invocation = invocation; self.label = label
        }
    }

    /// Recipe → the tool command that cleans it safely. Only cache-style,
    /// idempotent, re-downloadable commands — nothing that touches user data.
    public static let commands: [Command] = [
        .init(recipeID: "dev.npm.cacache", tool: "npm", invocation: "npm cache clean --force", label: "npm cache clean"),
        .init(recipeID: "dev.yarn.cache", tool: "yarn", invocation: "yarn cache clean", label: "yarn cache clean"),
        .init(recipeID: "dev.pnpm.store", tool: "pnpm", invocation: "pnpm store prune", label: "pnpm store prune"),
        .init(recipeID: "sys.homebrew.cache", tool: "brew", invocation: "brew cleanup -s", label: "brew cleanup"),
        .init(recipeID: "ml.pip.cache", tool: "pip3", invocation: "pip3 cache purge", label: "pip cache purge"),
        .init(recipeID: "ml.conda.pkgs", tool: "conda", invocation: "conda clean --tarballs --packages --yes", label: "conda clean"),
        .init(recipeID: "lang.go.modcache", tool: "go", invocation: "go clean -modcache", label: "go clean -modcache"),
        .init(recipeID: "lang.uv.cache", tool: "uv", invocation: "uv cache clean", label: "uv cache clean"),
        .init(recipeID: "lang.gem.cache", tool: "gem", invocation: "gem cleanup", label: "gem cleanup"),
    ]

    public static func command(for recipeID: String) -> Command? {
        commands.first { $0.recipeID == recipeID }
    }

    /// Which of the given tools are installed, resolved through the user's login
    /// shell so PATH matches their real setup (nvm, pyenv, Homebrew, …) — a GUI
    /// app's default PATH wouldn't find them otherwise.
    public static func availableTools(among tools: Set<String>) -> Set<String> {
        var found: Set<String> = []
        for tool in tools where shell("command -v \(tool)").code == 0 { found.insert(tool) }
        return found
    }

    public struct RunResult: Sendable {
        public let freedBytes: Int64
        public let succeeded: Bool
        public let output: String
    }

    /// Run the command and measure the real free-space delta.
    public static func run(_ command: Command) -> RunResult {
        let before = Volume.freeBytes()
        let r = shell(command.invocation)
        let after = Volume.freeBytes()
        return RunResult(freedBytes: max(0, after - before),
                         succeeded: r.code == 0,
                         output: String(r.text.suffix(1500)))
    }

    /// Run a command through the user's login shell, capturing combined output.
    private static func shell(_ command: String) -> (text: String, code: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        guard (try? task.run()) != nil else { return ("", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", task.terminationStatus)
    }
}
