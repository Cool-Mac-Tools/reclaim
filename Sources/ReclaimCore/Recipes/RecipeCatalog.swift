import Foundation

/// The v0 recipe library, seeded from the live 90+ GB cleanup case study.
/// Every entry is detection-only in the read-only phases. Sizes, tiers, and
/// impact language come from the product master plan (sections 11 & 13).
public enum RecipeCatalog {

    public static let all: [Recipe] =
        aiTools + apple + javascript + automation + general
        + virtualization + aiModels + mediaComms + creative + gaming
        + languages + system + browsers + coverage2

    // MARK: - AI coding tools

    public static let aiTools: [Recipe] = [
        Recipe(
            id: "dev.cursor.state-backup",
            displayName: "Cursor state database backup",
            group: "AI tools",
            paths: ["~/Library/Application Support/Cursor/User/globalStorage/state.vscdb.backup"],
            riskTier: .green,
            requiresQuit: ["Cursor"],
            action: .quarantine,
            explanation: "A backup copy of Cursor's state database. The live database (state.vscdb) holds your chat and agent history; this is a redundant snapshot Cursor made alongside it.",
            impact: "The live database is preserved. Cursor will recreate a backup on its own schedule.",
            recurrence: "Returns as Cursor rewrites its backup; grows with chat history."
        ),
        Recipe(
            id: "dev.cursor.state-live",
            displayName: "Cursor live state database",
            group: "AI tools",
            paths: ["~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"],
            riskTier: .yellow,
            thresholdBytes: 1024 * 1024 * 1024,
            requiresQuit: ["Cursor"],
            action: .reviewOnly,
            explanation: "Cursor's live state database, which stores chat and agent conversation history. On heavy-use machines this can exceed 10 GB.",
            impact: "Deleting or resetting it means old agent conversations will no longer reopen. Never auto-deleted — surfaced for awareness only.",
            recurrence: "Grows continuously with AI-assisted coding sessions."
        ),
        Recipe(
            id: "dev.cursor.logs",
            displayName: "Cursor logs",
            group: "AI tools",
            paths: ["~/Library/Application Support/Cursor/logs"],
            riskTier: .green,
            requiresQuit: ["Cursor"],
            action: .quarantine,
            explanation: "Diagnostic log files written by Cursor across sessions.",
            impact: "Logs are only needed for debugging Cursor issues. New logs are written on next launch.",
            recurrence: "Regrows slowly with use."
        ),
        Recipe(
            id: "dev.cursor.workspace-storage",
            displayName: "Cursor workspace storage",
            group: "AI tools",
            paths: ["~/Library/Application Support/Cursor/User/workspaceStorage"],
            riskTier: .yellow,
            requiresQuit: ["Cursor"],
            action: .reviewOnly,
            explanation: "Per-workspace state for every folder you have opened in Cursor, including workspaces for projects that no longer exist.",
            impact: "Removing storage for a workspace resets its editor state (open tabs, per-project history). Active projects should be kept.",
            recurrence: "Grows as new folders are opened."
        ),
        Recipe(
            id: "dev.claude.cache",
            displayName: "Claude app caches",
            group: "AI tools",
            paths: ["~/Library/Caches/com.anthropic.claudefordesktop", "~/.claude/projects"],
            riskTier: .yellow,
            action: .reviewOnly,
            explanation: "Claude desktop caches and Claude Code project history (transcripts, session state).",
            impact: "Cache is regenerable; project history contains past agent sessions that will not reopen if removed.",
            recurrence: "Grows with Claude usage."
        ),
    ]

    // MARK: - Apple development

    public static let apple: [Recipe] = [
        Recipe(
            id: "dev.xcode.previews",
            displayName: "Xcode preview data",
            group: "Xcode",
            paths: ["~/Library/Developer/Xcode/UserData/Previews"],
            riskTier: .green,
            requiresQuit: ["Xcode"],
            action: .quarantine,
            explanation: "Generated SwiftUI preview data from past development sessions. In the case study 13 GB remained even after Xcode was uninstalled.",
            impact: "No source code, archives, signing profiles, or runtimes are affected. Previews rebuild when used again.",
            recurrence: "Low unless SwiftUI previews are used heavily."
        ),
        Recipe(
            id: "dev.xcode.derived-data",
            displayName: "Xcode DerivedData",
            group: "Xcode",
            paths: ["~/Library/Developer/Xcode/DerivedData"],
            riskTier: .green,
            requiresQuit: ["Xcode"],
            action: .quarantine,
            explanation: "Intermediate build products, indexes, and module caches for every project Xcode has built.",
            impact: "Projects rebuild from source on next build (first build is slower). Nothing is lost.",
            recurrence: "Returns with every build; the classic Xcode space hog."
        ),
        Recipe(
            id: "dev.xcode.archives",
            displayName: "Xcode archives",
            group: "Xcode",
            paths: ["~/Library/Developer/Xcode/Archives"],
            riskTier: .yellow,
            action: .reviewOnly,
            explanation: "App archives created by Product → Archive, including dSYMs used to symbolicate crash reports for shipped builds.",
            impact: "Deleting an archive removes the ability to re-export or symbolicate that exact build. Review per-archive.",
            recurrence: "Grows with each release archive."
        ),
        Recipe(
            id: "dev.xcode.device-support",
            displayName: "iOS device support files",
            group: "Xcode",
            paths: ["~/Library/Developer/Xcode/iOS DeviceSupport"],
            riskTier: .green,
            action: .quarantine,
            explanation: "Debug symbols copied from every physical iOS device/OS version ever attached for debugging.",
            impact: "Re-copied automatically the next time the device is attached (takes a few minutes).",
            recurrence: "Returns when devices attach with new OS versions."
        ),
        Recipe(
            id: "dev.simulator.devices",
            displayName: "iOS Simulator devices",
            group: "Xcode",
            paths: ["~/Library/Developer/CoreSimulator/Devices"],
            riskTier: .yellow,
            action: .reviewOnly,
            explanation: "Local simulator device data — app installs, settings, and media inside each simulated device.",
            impact: "Stale devices can be removed via `xcrun simctl delete unavailable`; active ones lose installed test apps and state. Listed per-device before action.",
            recurrence: "Grows with simulator use."
        ),
        Recipe(
            id: "dev.simulator.caches",
            displayName: "CoreSimulator caches (dyld)",
            group: "Xcode",
            paths: ["~/Library/Developer/CoreSimulator/Caches"],
            riskTier: .green,
            action: .supportedCLI,
            explanation: "Simulator dyld caches. In the case study a 3.8 GB cache accompanied an orphaned runtime.",
            impact: "Regenerated when simulators run. Runtimes themselves are managed assets and must go through simctl — never raw deletion.",
            recurrence: "Returns with simulator use."
        ),
        Recipe(
            id: "dev.simulator.runtimes",
            displayName: "iOS Simulator runtimes",
            group: "Xcode",
            paths: ["/Library/Developer/CoreSimulator/Volumes", "/Library/Developer/CoreSimulator/Images"],
            riskTier: .red,
            action: .supportedCLI,
            explanation: "Mounted, protected simulator runtime images managed by MobileAsset. The case study's 11.6 GB win required the supported `xcrun simctl runtime` flow.",
            impact: "Raw `rm` is unsafe and blocked by macOS. Only official runtime management (simctl / Xcode components) may remove these.",
            recurrence: "Returns when new runtimes are downloaded."
        ),
        Recipe(
            id: "dev.spm.cache",
            displayName: "Swift Package Manager cache",
            group: "Xcode",
            paths: ["~/Library/Caches/org.swift.swiftpm"],
            riskTier: .green,
            action: .quarantine,
            explanation: "Cached checkouts of Swift package dependencies.",
            impact: "Packages re-download on next resolve. Keep if actively doing Swift development (case study kept it for that reason).",
            recurrence: "Returns with Swift builds."
        ),
    ]

    // MARK: - JavaScript

    public static let javascript: [Recipe] = [
        Recipe(
            id: "dev.npm.cacache",
            displayName: "npm downloaded package cache",
            group: "JavaScript",
            paths: ["~/.npm/_cacache"],
            riskTier: .green,
            action: .supportedCLI,
            explanation: "npm's content-addressable cache of every downloaded package tarball. 7.9 GB in the case study.",
            impact: "Packages re-download when needed; installed project dependencies (node_modules) are untouched. Prefers `npm cache clean --force`; falls back to ownership-aware quarantine.",
            recurrence: "Likely to grow with package installs."
        ),
        Recipe(
            id: "dev.npm.npx",
            displayName: "npx temporary packages",
            group: "JavaScript",
            paths: ["~/.npm/_npx"],
            riskTier: .green,
            action: .quarantine,
            explanation: "Packages fetched on-the-fly by `npx` invocations. 1.3 GB in the case study.",
            impact: "Tools re-download the next time they are invoked with npx.",
            recurrence: "Returns with npx use."
        ),
        Recipe(
            id: "dev.yarn.cache",
            displayName: "Yarn cache",
            group: "JavaScript",
            paths: ["~/Library/Caches/Yarn", "~/.yarn/berry/cache"],
            riskTier: .green,
            action: .supportedCLI,
            explanation: "Yarn's global package cache.",
            impact: "Packages re-download on next install. Prefers `yarn cache clean`.",
            recurrence: "Returns with installs."
        ),
        Recipe(
            id: "dev.pnpm.store",
            displayName: "pnpm content store",
            group: "JavaScript",
            paths: ["~/Library/pnpm/store", "~/.pnpm-store"],
            riskTier: .blue,
            action: .supportedCLI,
            explanation: "pnpm's shared content-addressable store. Unlike npm's cache, active projects hard-link into it.",
            impact: "Use `pnpm store prune` to remove only unreferenced packages — raw deletion breaks existing node_modules links.",
            recurrence: "Grows with installs; prune is the safe path."
        ),
        Recipe(
            id: "dev.node-gyp.cache",
            displayName: "node-gyp headers cache",
            group: "JavaScript",
            paths: ["~/Library/Caches/node-gyp", "~/.node-gyp"],
            riskTier: .green,
            action: .quarantine,
            explanation: "Node.js headers downloaded to compile native addons.",
            impact: "Re-downloaded on the next native module build.",
            recurrence: "Returns when native modules compile."
        ),
        Recipe(
            id: "dev.nextjs.builds",
            displayName: "Next.js build outputs",
            group: "JavaScript",
            paths: ["~/**/.next/cache"],
            riskTier: .green,
            thresholdBytes: 200 * 1024 * 1024,
            action: .reviewOnly,
            explanation: "Next.js build caches inside project folders.",
            impact: "Rebuilt on next `next build`/`dev`. Surfaced repo-aware — never deleted without seeing which project it belongs to.",
            recurrence: "Returns with builds."
        ),
    ]

    // MARK: - Browser automation

    public static let automation: [Recipe] = [
        Recipe(
            id: "dev.playwright.browsers",
            displayName: "Playwright browser binaries",
            group: "Automation",
            paths: ["~/Library/Caches/ms-playwright"],
            riskTier: .green,
            action: .quarantine,
            explanation: "Chromium, Firefox, and WebKit builds downloaded by Playwright for testing.",
            impact: "Browsers re-download on next `playwright install` or test run (large download).",
            recurrence: "Returns with Playwright use; one copy per browser version."
        ),
        Recipe(
            id: "dev.puppeteer.browsers",
            displayName: "Puppeteer browser cache",
            group: "Automation",
            paths: ["~/.cache/puppeteer"],
            riskTier: .green,
            action: .quarantine,
            explanation: "Chrome/Chromium binaries downloaded by Puppeteer. 1.0 GB in the case study.",
            impact: "Re-downloads on next Puppeteer install/run.",
            recurrence: "Returns with Puppeteer use."
        ),
    ]

    // MARK: - General

    public static let general: [Recipe] = [
        Recipe(
            id: "app.messages.preview-cache",
            displayName: "Messages preview cache",
            group: "General",
            paths: ["~/Library/Messages/Caches"],
            riskTier: .green,
            requiresQuit: ["Messages"],
            action: .quarantine,
            explanation: "Generated previews of message attachments — separate from the attachments themselves. 8.8 GB in the case study.",
            impact: "Actual attachments remain. Previews regenerate as conversations are viewed.",
            recurrence: "Regrows with Messages use."
        ),
        Recipe(
            id: "app.messages.tmp-copies",
            displayName: "Messages temporary copies",
            group: "General",
            paths: ["~/Library/Containers/com.apple.MobileSMS/Data/tmp"],
            riskTier: .green,
            requiresQuit: ["Messages"],
            action: .quarantine,
            explanation: "Temporary attachment copies in the Messages container. 3.0 GB in the case study.",
            impact: "Temp items only; original attachments untouched.",
            recurrence: "Regrows with attachment viewing."
        ),
        Recipe(
            id: "app.messages.attachments",
            displayName: "Old Messages attachments",
            group: "General",
            paths: ["~/Library/Messages/Attachments"],
            riskTier: .orange,
            thresholdBytes: 1024 * 1024 * 1024,
            requiresQuit: ["Messages"],
            action: .reviewOnly,
            explanation: "The actual photos, videos, and files received in Messages. 13.5 GB in the case study.",
            impact: "Personal content. iCloud sync behavior means local deletion may propagate — requires explicit per-item review with an age/size filter and a clear cloud warning. Never auto-deleted.",
            recurrence: "Grows with received attachments."
        ),
        Recipe(
            id: "app.chrome.cache",
            displayName: "Chrome cache",
            group: "General",
            paths: ["~/Library/Caches/Google/Chrome"],
            riskTier: .green,
            requiresQuit: ["Google Chrome"],
            action: .quarantine,
            explanation: "Browser cache — separate from profiles, passwords, bookmarks, and history in Application Support. 2.9 GB in the case study.",
            impact: "Pages re-cache as you browse. Profile data untouched.",
            recurrence: "Regrows with browsing."
        ),
        Recipe(
            id: "app.electron.shipit",
            displayName: "Electron updater staging (ShipIt)",
            group: "General",
            paths: ["~/Library/Caches/*ShipIt*", "~/Library/Caches/com.*.ShipIt"],
            riskTier: .green,
            action: .quarantine,
            explanation: "Update staging folders left by Electron apps (Claude, Discord, Notion, Slack, Screen Studio and friends). Several GB combined in the case study.",
            impact: "Safe once the owning app is closed. Returns after the app's next self-update.",
            recurrence: "Returns after app updates."
        ),
        Recipe(
            id: "sys.homebrew.cache",
            displayName: "Homebrew download cache",
            group: "General",
            paths: ["~/Library/Caches/Homebrew"],
            riskTier: .green,
            action: .supportedCLI,
            explanation: "Downloaded bottles and old formula versions kept by Homebrew.",
            impact: "Prefers `brew cleanup` (dry-run first). Never raw-deletes Cellar packages.",
            recurrence: "Returns with brew installs/upgrades."
        ),
        Recipe(
            id: "user.downloads.installers",
            displayName: "Downloaded installers (DMG/PKG)",
            group: "General",
            paths: ["~/Downloads/*.dmg", "~/Downloads/*.pkg", "~/Downloads/*.iso"],
            riskTier: .blue,
            thresholdBytes: 10 * 1024 * 1024,
            action: .reviewOnly,
            explanation: "Installer images and packages in Downloads, typically for apps already installed.",
            impact: "User files — surfaced with app-installed detection and age; each requires approval.",
            recurrence: "Accumulates with every app download."
        ),
        Recipe(
            id: "sys.trash",
            displayName: "Trash",
            group: "General",
            paths: ["~/.Trash"],
            riskTier: .blue,
            action: .reviewOnly,
            explanation: "Items already moved to Trash but not yet emptied.",
            impact: "Emptying is permanent. Reclaim reports the size; the user decides.",
            recurrence: "Refills with normal use."
        ),
    ]
}
