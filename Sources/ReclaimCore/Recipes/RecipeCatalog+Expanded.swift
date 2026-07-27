import Foundation

/// Expanded catalog from the July 2026 deep-research pass (105-agent sweep,
/// claims adversarially verified). Recipes marked `.verified` rest on primary
/// vendor docs; `.communityKnown` are well-known paths pending empirical
/// verification — detection-only until then.
extension RecipeCatalog {

    // MARK: - Virtualization & containers

    public static let virtualization: [Recipe] = [
        Recipe(
            id: "vm.docker.raw",
            displayName: "Docker Desktop disk image",
            group: "Virtualization",
            paths: [
                "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
                "~/Library/Containers/com.docker.docker/Data/vms/0/Docker.qcow2",
            ],
            riskTier: .yellow,
            thresholdBytes: 1024 * 1024 * 1024,
            requiresQuit: ["Docker"],
            action: .supportedCLI,
            explanation: "All Docker containers and images live inside this one sparse disk image. Its apparent size can vastly exceed real usage (Docker documents 64 GB apparent vs 2.3 GB actual) — Reclaim measures the real allocated size.",
            impact: "Space is freed ONLY by removing images/containers via `docker system prune`. WARNING (per Docker's official docs): shrinking the image via Docker Settings → Resources deletes the ENTIRE image — all containers and images are lost. Reclaim never suggests the slider.",
            recurrence: "Grows with image pulls and container writes; never shrinks on its own."
        ),
        Recipe(
            id: "vm.parallels.pvm",
            displayName: "Parallels virtual machines",
            group: "Virtualization",
            paths: ["~/Parallels", "~/Documents/Parallels"],
            riskTier: .orange,
            thresholdBytes: 2 * 1024 * 1024 * 1024,
            action: .reviewOnly,
            explanation: "Parallels .pvm expanding disks grow with guest contents and are never reduced by deleting files inside Windows — an explicit reclaim step is required (Parallels KB 123553).",
            impact: "The VM itself is user data — never auto-deleted. The safe lever is Parallels' File → 'Free Up Disk Space…' wizard (removes VM snapshots, suspended-state .mem files, then compacts). Compaction is blocked while VM snapshots exist.",
            recurrence: "Regrows with guest usage; enable 'Reclaim disk space on shutdown' to mitigate."
        ),
        Recipe(
            id: "vm.utm.images",
            displayName: "UTM virtual machines",
            group: "Virtualization",
            paths: ["~/Library/Containers/com.utmapp.UTM/Data/Documents"],
            riskTier: .orange,
            thresholdBytes: 2 * 1024 * 1024 * 1024,
            action: .reviewOnly,
            explanation: "UTM virtual machine disk images.",
            impact: "VMs are user data. Surfaced for review with last-used dates; sparse sizing measured correctly.",
            recurrence: "Grows with guest usage.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "vm.android.avd",
            displayName: "Android emulators and SDKs",
            group: "Virtualization",
            paths: ["~/.android/avd", "~/Library/Android/sdk/system-images", "~/Library/Android/sdk"],
            riskTier: .yellow,
            thresholdBytes: 1024 * 1024 * 1024,
            action: .reviewOnly,
            explanation: "Android Studio emulator devices (AVDs) and SDK system images.",
            impact: "Stale AVDs and old SDK platform versions can be removed via Android Studio's SDK Manager; active emulators lose state if deleted raw.",
            recurrence: "Grows with SDK/emulator updates.",
            confidence: .communityKnown
        ),
    ]

    // MARK: - AI / ML era

    public static let aiModels: [Recipe] = [
        Recipe(
            id: "ml.ollama.models",
            displayName: "Ollama models",
            group: "AI / ML",
            paths: ["~/.ollama/models"],
            riskTier: .blue,
            thresholdBytes: 1024 * 1024 * 1024,
            action: .supportedCLI,
            explanation: "Local LLM weights downloaded by Ollama, hidden in ~/.ollama (official default per Ollama docs). Individual models are often 4–70 GB.",
            impact: "Remove per-model with `ollama rm <model>`; re-downloadable but large. Power users can relocate the store via OLLAMA_MODELS.",
            recurrence: "Grows with every `ollama pull`."
        ),
        Recipe(
            id: "ml.huggingface.cache",
            displayName: "Hugging Face cache",
            group: "AI / ML",
            paths: ["~/.cache/huggingface"],
            riskTier: .blue,
            thresholdBytes: 500 * 1024 * 1024,
            action: .reviewOnly,
            explanation: "Models, datasets, and hub downloads cached by transformers/diffusers and friends.",
            impact: "Re-downloads on next use (can be tens of GB). `huggingface-cli delete-cache` is the supported per-item path.",
            recurrence: "Grows with model usage.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "ml.lmstudio.models",
            displayName: "LM Studio models",
            group: "AI / ML",
            paths: ["~/.lmstudio/models", "~/.cache/lm-studio/models"],
            riskTier: .blue,
            thresholdBytes: 1024 * 1024 * 1024,
            action: .reviewOnly,
            explanation: "GGUF model files downloaded through LM Studio.",
            impact: "Deletable from LM Studio's model manager; re-downloadable but large.",
            recurrence: "Grows with downloads.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "ml.torch.cache",
            displayName: "PyTorch hub cache",
            group: "AI / ML",
            paths: ["~/.cache/torch"],
            riskTier: .green,
            action: .quarantine,
            explanation: "Model weights auto-downloaded by torch.hub and torchvision.",
            impact: "Re-downloads on next use.",
            recurrence: "Returns with torch usage.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "ml.pip.cache",
            displayName: "pip cache",
            group: "AI / ML",
            paths: ["~/Library/Caches/pip"],
            riskTier: .green,
            action: .supportedCLI,
            explanation: "Downloaded Python wheels and source archives.",
            impact: "Prefers `pip cache purge`; packages re-download on install.",
            recurrence: "Returns with pip installs.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "ml.conda.pkgs",
            displayName: "Conda package cache",
            group: "AI / ML",
            paths: ["~/miniconda3/pkgs", "~/anaconda3/pkgs", "~/miniforge3/pkgs"],
            riskTier: .green,
            thresholdBytes: 500 * 1024 * 1024,
            action: .supportedCLI,
            explanation: "Extracted and archived conda packages kept after installs.",
            impact: "Prefers `conda clean --all --dry-run` first; environments are untouched.",
            recurrence: "Returns with conda installs.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "ml.whisper.cache",
            displayName: "Whisper model cache",
            group: "AI / ML",
            paths: ["~/.cache/whisper"],
            riskTier: .green,
            thresholdBytes: 100 * 1024 * 1024,
            action: .quarantine,
            explanation: "Speech-recognition model weights downloaded by openai-whisper.",
            impact: "Re-downloads on next transcription run.",
            recurrence: "Returns with use.",
            confidence: .communityKnown
        ),
    ]

    // MARK: - Media & communications

    public static let mediaComms: [Recipe] = [
        Recipe(
            id: "app.spotify.cache",
            displayName: "Spotify persistent cache",
            group: "Media & comms",
            paths: ["~/Library/Application Support/Spotify/PersistentCache", "~/Library/Caches/com.spotify.client"],
            riskTier: .green,
            requiresQuit: ["Spotify"],
            action: .quarantine,
            explanation: "Streamed-track cache Spotify keeps for smooth playback; community reports of 10–30 GB are common.",
            impact: "Downloaded-for-offline playlists live elsewhere; streaming re-caches as you listen. Spotify's own settings expose a cache limit.",
            recurrence: "Regrows with listening.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "app.slack.cache",
            displayName: "Slack cache",
            group: "Media & comms",
            paths: ["~/Library/Application Support/Slack/Cache", "~/Library/Application Support/Slack/Service Worker/CacheStorage"],
            riskTier: .green,
            requiresQuit: ["Slack"],
            action: .quarantine,
            explanation: "Slack's Electron web caches and service-worker storage.",
            impact: "Message history is server-side; caches rebuild on next launch.",
            recurrence: "Regrows with use.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "app.discord.cache",
            displayName: "Discord cache",
            group: "Media & comms",
            paths: ["~/Library/Application Support/discord/Cache", "~/Library/Application Support/discord/Code Cache"],
            riskTier: .green,
            requiresQuit: ["Discord"],
            action: .quarantine,
            explanation: "Discord's Electron caches for media and code.",
            impact: "Rebuilds on next launch; account data is server-side.",
            recurrence: "Regrows with use.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "app.teams.cache",
            displayName: "Microsoft Teams cache",
            group: "Media & comms",
            paths: ["~/Library/Group Containers/UBF8T346G9.com.microsoft.teams", "~/Library/Containers/com.microsoft.teams2"],
            riskTier: .yellow,
            requiresQuit: ["Microsoft Teams"],
            action: .reviewOnly,
            explanation: "Teams container data — mixed cache and account state.",
            impact: "Caches rebuild, but the container also holds settings; surfaced for review rather than bulk deletion.",
            recurrence: "Regrows with use.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "app.zoom.recordings",
            displayName: "Zoom local recordings",
            group: "Media & comms",
            paths: ["~/Documents/Zoom"],
            riskTier: .orange,
            thresholdBytes: 500 * 1024 * 1024,
            action: .reviewOnly,
            explanation: "Local meeting recordings saved by Zoom.",
            impact: "Personal content — recordings may be irreplaceable. Explicit per-item review with dates and sizes; never auto-deleted.",
            recurrence: "Grows with recorded meetings.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "app.whatsapp.media",
            displayName: "WhatsApp media",
            group: "Media & comms",
            paths: ["~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"],
            riskTier: .orange,
            thresholdBytes: 1024 * 1024 * 1024,
            requiresQuit: ["WhatsApp"],
            action: .reviewOnly,
            explanation: "Received photos, videos, and message store for WhatsApp Desktop.",
            impact: "Personal content with phone-sync implications — never auto-deleted; review only.",
            recurrence: "Grows with received media.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "app.telegram.cache",
            displayName: "Telegram media cache",
            group: "Media & comms",
            paths: ["~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"],
            riskTier: .yellow,
            thresholdBytes: 500 * 1024 * 1024,
            requiresQuit: ["Telegram"],
            action: .reviewOnly,
            explanation: "Telegram's local media cache — messages and media remain on Telegram's cloud.",
            impact: "Telegram's own Settings → Data and Storage can clear this with in-app control; re-downloads on view.",
            recurrence: "Regrows with use.",
            confidence: .communityKnown
        ),
    ]

    // MARK: - Creative tools

    public static let creative: [Recipe] = [
        Recipe(
            id: "app.adobe.media-cache",
            displayName: "Adobe media cache",
            group: "Creative",
            paths: [
                "~/Library/Application Support/Adobe/Common/Media Cache Files",
                "~/Library/Application Support/Adobe/Common/Media Cache",
            ],
            riskTier: .green,
            requiresQuit: ["Adobe Premiere Pro", "Adobe Media Encoder", "Adobe After Effects"],
            action: .quarantine,
            explanation: "Rendered preview/conform files Premiere and After Effects generate for every imported clip. Notorious multi-GB accumulator.",
            impact: "Projects and source media untouched; Adobe apps rebuild caches on open (first scrub is slower). Adobe's own preferences expose cache cleanup.",
            recurrence: "Regrows with editing.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "app.lightroom.previews",
            displayName: "Lightroom preview caches",
            group: "Creative",
            paths: ["~/Pictures/*.lrdata"],
            riskTier: .yellow,
            thresholdBytes: 1024 * 1024 * 1024,
            requiresQuit: ["Adobe Lightroom Classic"],
            action: .reviewOnly,
            explanation: "Lightroom Classic preview bundles (.lrdata) beside catalogs — regenerable, but rebuilding thousands of previews is slow.",
            impact: "Catalog and originals untouched; previews rebuild on demand. Smart Previews (.lrdata too) enable offline editing — flagged before removal.",
            recurrence: "Regrows with catalog use.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "app.fcp.render",
            displayName: "Final Cut render files",
            group: "Creative",
            paths: ["~/Movies/*.fcpbundle"],
            riskTier: .yellow,
            thresholdBytes: 2 * 1024 * 1024 * 1024,
            requiresQuit: ["Final Cut Pro"],
            action: .supportedCLI,
            explanation: "Final Cut libraries contain regenerable render/proxy media alongside irreplaceable originals — the bundle is measured whole, never opened by file deletion.",
            impact: "The safe path is Final Cut's own File → Delete Generated Library Files. Reclaim only points there; it never reaches inside the bundle.",
            recurrence: "Regrows with editing.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "app.garageband.library",
            displayName: "GarageBand/Logic sound library",
            group: "Creative",
            paths: ["/Library/Application Support/GarageBand", "/Library/Application Support/Logic"],
            riskTier: .blue,
            thresholdBytes: 1024 * 1024 * 1024,
            action: .supportedCLI,
            explanation: "Instrument and loop libraries downloaded by GarageBand/Logic — often 2–10+ GB, kept even if the app is unused.",
            impact: "Re-downloadable via the apps' Sound Library manager. If GarageBand itself is gone, the library is orphaned weight.",
            recurrence: "Returns only if re-downloaded in-app.",
            confidence: .communityKnown
        ),
    ]

    // MARK: - Gaming

    public static let gaming: [Recipe] = [
        Recipe(
            id: "game.steam.apps",
            displayName: "Steam game libraries",
            group: "Gaming",
            paths: ["~/Library/Application Support/Steam/steamapps"],
            riskTier: .yellow,
            thresholdBytes: 1024 * 1024 * 1024,
            requiresQuit: ["Steam"],
            action: .supportedCLI,
            explanation: "Installed Steam games and shader caches.",
            impact: "Uninstall via Steam itself (preserves cloud saves). Raw deletion desyncs Steam's manifest.",
            recurrence: "Grows with installs and shader updates.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "game.epic.apps",
            displayName: "Epic Games installs",
            group: "Gaming",
            paths: ["~/Library/Application Support/Epic"],
            riskTier: .yellow,
            thresholdBytes: 1024 * 1024 * 1024,
            action: .reviewOnly,
            explanation: "Epic Games Launcher data and installed games.",
            impact: "Uninstall through the launcher; saves may be cloud-synced per game.",
            recurrence: "Grows with installs.",
            confidence: .communityKnown
        ),
    ]

    // MARK: - Language runtimes

    public static let languages: [Recipe] = [
        Recipe(
            id: "lang.go.modcache",
            displayName: "Go module cache",
            group: "Languages",
            paths: ["~/go/pkg/mod"],
            riskTier: .green,
            thresholdBytes: 500 * 1024 * 1024,
            action: .supportedCLI,
            explanation: "Downloaded Go module sources, shared across projects.",
            impact: "Prefers `go clean -modcache` (the cache is read-only on disk; raw rm hits permission errors). Modules re-download on build.",
            recurrence: "Returns with Go builds.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "lang.rust.cargo",
            displayName: "Cargo registry cache",
            group: "Languages",
            paths: ["~/.cargo/registry"],
            riskTier: .green,
            thresholdBytes: 500 * 1024 * 1024,
            action: .quarantine,
            explanation: "Downloaded Rust crate sources and archives. (Per-project target/ dirs are found by the repo-aware module, not bulk-deleted.)",
            impact: "Crates re-download on next build.",
            recurrence: "Returns with Rust builds.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "lang.gradle.caches",
            displayName: "Gradle caches",
            group: "Languages",
            paths: ["~/.gradle/caches"],
            riskTier: .green,
            thresholdBytes: 500 * 1024 * 1024,
            action: .quarantine,
            explanation: "Gradle dependency and build caches (Android/JVM projects).",
            impact: "Dependencies re-download on next build; first build slower.",
            recurrence: "Returns with builds.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "lang.maven.repo",
            displayName: "Maven local repository",
            group: "Languages",
            paths: ["~/.m2/repository"],
            riskTier: .green,
            thresholdBytes: 500 * 1024 * 1024,
            action: .quarantine,
            explanation: "Downloaded JVM dependencies shared across Maven projects.",
            impact: "Re-download on next build.",
            recurrence: "Returns with builds.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "lang.uv.cache",
            displayName: "uv cache",
            group: "Languages",
            paths: ["~/.cache/uv"],
            riskTier: .green,
            action: .supportedCLI,
            explanation: "Python package cache for the uv package manager.",
            impact: "Prefers `uv cache clean`; re-downloads on install.",
            recurrence: "Returns with installs.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "lang.gem.cache",
            displayName: "Ruby gems",
            group: "Languages",
            paths: ["~/.gem"],
            riskTier: .green,
            thresholdBytes: 200 * 1024 * 1024,
            action: .supportedCLI,
            explanation: "Installed Ruby gems and their cached archives.",
            impact: "Prefers `gem cleanup` for old versions; active gems untouched.",
            recurrence: "Returns with gem installs.",
            confidence: .communityKnown
        ),
    ]

    // MARK: - System (beyond the case study)

    public static let system: [Recipe] = [
        Recipe(
            id: "sys.ios.backups",
            displayName: "iOS device backups",
            group: "System",
            paths: ["~/Library/Application Support/MobileSync/Backup"],
            riskTier: .orange,
            thresholdBytes: 1024 * 1024 * 1024,
            action: .reviewOnly,
            explanation: "Full local backups of iPhones/iPads made via Finder. Backups of devices you no longer own are classic dead weight — but a backup may be the ONLY copy of a lost device's data.",
            impact: "Reviewed per-device with device name and backup date, via Finder's Manage Backups. Never auto-deleted.",
            recurrence: "Grows with each device backup.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "sys.diagnostics.reports",
            displayName: "Diagnostic and crash reports",
            group: "System",
            paths: ["~/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"],
            riskTier: .green,
            thresholdBytes: 100 * 1024 * 1024,
            action: .quarantine,
            explanation: "Crash logs and diagnostic reports accumulated over time.",
            impact: "Only needed for debugging past crashes; new reports generate as needed.",
            recurrence: "Regrows slowly.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "sys.quicklook.thumbnails",
            displayName: "Quick Look thumbnail cache",
            group: "System",
            paths: ["~/Library/Caches/com.apple.QuickLook.thumbnailcache"],
            riskTier: .green,
            thresholdBytes: 100 * 1024 * 1024,
            action: .quarantine,
            explanation: "Cached file-preview thumbnails.",
            impact: "Regenerates as files are previewed. Note: some Quick Look data is DataVault-protected — Reclaim reports rather than fights the protection.",
            recurrence: "Regrows with use.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "user.screenshots",
            displayName: "Screen recordings and screenshots",
            group: "System",
            paths: ["~/Desktop/Screenshot*.png", "~/Desktop/Screen Recording*.mov", "~/Movies/Screen Recording*.mov"],
            riskTier: .orange,
            thresholdBytes: 200 * 1024 * 1024,
            action: .reviewOnly,
            explanation: "Screenshots and screen recordings accumulating on the Desktop — recordings especially can be hundreds of MB each.",
            impact: "Personal content: review with thumbnails and dates. Old recordings are the classic 'personal but you probably want it gone' category.",
            recurrence: "Grows with capture habits.",
            confidence: .communityKnown
        ),
    ]

    // MARK: - Browsers (beyond Chrome)

    public static let browsers: [Recipe] = [
        Recipe(
            id: "app.firefox.cache",
            displayName: "Firefox cache",
            group: "Browsers",
            paths: ["~/Library/Caches/Firefox"],
            riskTier: .green,
            requiresQuit: ["firefox"],
            action: .quarantine,
            explanation: "Firefox's disk cache — separate from profiles, bookmarks, and passwords.",
            impact: "Pages re-cache while browsing; profile data untouched.",
            recurrence: "Regrows with browsing.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "app.arc.cache",
            displayName: "Arc cache",
            group: "Browsers",
            paths: ["~/Library/Caches/Arc", "~/Library/Application Support/Arc/User Data/Default/Cache"],
            riskTier: .green,
            requiresQuit: ["Arc"],
            action: .quarantine,
            explanation: "Arc browser cache (Chromium-based).",
            impact: "Rebuilds while browsing; profile untouched.",
            recurrence: "Regrows with browsing.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "app.edge.cache",
            displayName: "Edge cache",
            group: "Browsers",
            paths: ["~/Library/Caches/Microsoft Edge"],
            riskTier: .green,
            requiresQuit: ["Microsoft Edge"],
            action: .quarantine,
            explanation: "Microsoft Edge browser cache.",
            impact: "Rebuilds while browsing.",
            recurrence: "Regrows with browsing.",
            confidence: .communityKnown
        ),
        Recipe(
            id: "app.brave.cache",
            displayName: "Brave cache",
            group: "Browsers",
            paths: ["~/Library/Caches/BraveSoftware"],
            riskTier: .green,
            requiresQuit: ["Brave Browser"],
            action: .quarantine,
            explanation: "Brave browser cache.",
            impact: "Rebuilds while browsing.",
            recurrence: "Regrows with browsing.",
            confidence: .communityKnown
        ),
    ]

    // MARK: - Coverage gaps (July 2026): high-value locations not yet covered.
    // Detection-only, community-sourced paths — verify empirically before any
    // action is ever automated.
    public static let coverage2: [Recipe] = [
        // ── Virtualization / containers ─────────────────────────────
        Recipe(
            id: "vm.orbstack.data",
            displayName: "OrbStack data",
            group: "Virtualization",
            paths: ["~/.orbstack/data", "~/Library/Group Containers/HUAQ24HBR6.dev.orbstack"],
            riskTier: .yellow, thresholdBytes: 1 * 1024 * 1024 * 1024,
            requiresQuit: ["OrbStack"], action: .reviewOnly,
            explanation: "OrbStack's Linux/Docker disk image — containers, images, and volumes.",
            impact: "Holds live containers and images. Prune inside OrbStack; sizing is measured on the real allocation.",
            recurrence: "Grows as you build images and run containers.",
            confidence: .communityKnown),
        Recipe(
            id: "vm.vmware.images",
            displayName: "VMware Fusion virtual machines",
            group: "Virtualization",
            paths: ["~/Virtual Machines.localized", "~/Documents/Virtual Machines.localized"],
            riskTier: .orange, thresholdBytes: 2 * 1024 * 1024 * 1024,
            action: .reviewOnly,
            explanation: "VMware Fusion virtual machine bundles.",
            impact: "VMs are user data — surfaced for review with last-used dates, never auto-removed.",
            recurrence: "Grows with guest usage.",
            confidence: .communityKnown),
        // ── System ──────────────────────────────────────────────────
        Recipe(
            id: "sys.logs",
            displayName: "Log files",
            group: "System",
            paths: ["~/Library/Logs"],
            riskTier: .green, action: .quarantine,
            explanation: "Application and system log files that accumulate over time.",
            impact: "Safe to clear — apps recreate logs as needed. Only affects historical debugging.",
            recurrence: "Regrows steadily as apps run.",
            confidence: .communityKnown),
        Recipe(
            id: "sys.ios.updates",
            displayName: "iOS/iPadOS software updates",
            group: "System",
            paths: ["~/Library/iTunes/iPhone Software Updates",
                    "~/Library/iTunes/iPad Software Updates"],
            riskTier: .blue, action: .quarantine,
            explanation: "Downloaded .ipsw firmware images for restoring/updating devices.",
            impact: "Re-downloaded automatically if you restore or update a device.",
            recurrence: "Reappears when a new device update downloads.",
            confidence: .communityKnown),
        Recipe(
            id: "app.podcasts.downloads",
            displayName: "Apple Podcasts downloads",
            group: "Media & comms",
            paths: ["~/Library/Group Containers/243LU875E5.groups.com.apple.podcasts"],
            riskTier: .blue, action: .quarantine,
            explanation: "Episodes downloaded for offline listening.",
            impact: "Re-downloadable from the Podcasts app; subscriptions and history are untouched.",
            recurrence: "Grows as new episodes auto-download.",
            confidence: .communityKnown),
        Recipe(
            id: "app.mail.downloads",
            displayName: "Mail downloads",
            group: "Media & comms",
            paths: ["~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"],
            riskTier: .blue, requiresQuit: ["Mail"], action: .quarantine,
            explanation: "Attachments Mail saved to its temporary downloads folder.",
            impact: "Originals stay in the messages — these are just cached copies.",
            recurrence: "Regrows as you open attachments.",
            confidence: .communityKnown),
        // ── Creative ────────────────────────────────────────────────
        Recipe(
            id: "app.adobe.cameraraw",
            displayName: "Adobe Camera Raw cache",
            group: "Creative",
            paths: ["~/Library/Caches/Adobe Camera Raw 2"],
            riskTier: .green, action: .quarantine,
            explanation: "Cached raw-photo previews used by Lightroom/Photoshop.",
            impact: "Rebuilds on demand when you next edit those photos.",
            recurrence: "Regrows as you process raw images.",
            confidence: .communityKnown),
        // ── Developer ───────────────────────────────────────────────
        Recipe(
            id: "dev.jetbrains.caches",
            displayName: "JetBrains IDE caches",
            group: "Languages",
            paths: ["~/Library/Caches/JetBrains"],
            riskTier: .green, action: .quarantine,
            explanation: "Caches and indexes for IntelliJ, PyCharm, WebStorm, and other JetBrains IDEs.",
            impact: "IDEs re-index projects on next open; settings and projects are untouched.",
            recurrence: "Rebuilds as you work in projects.",
            confidence: .communityKnown),
        Recipe(
            id: "dev.vscode.cache",
            displayName: "VS Code caches",
            group: "AI tools",
            paths: ["~/Library/Application Support/Code/Cache",
                    "~/Library/Application Support/Code/CachedData",
                    "~/Library/Application Support/Code/CachedExtensionVSIXs"],
            riskTier: .green, requiresQuit: ["Code"], action: .quarantine,
            explanation: "Visual Studio Code's on-disk caches and cached extension packages.",
            impact: "Rebuilds on next launch; extensions and settings are untouched.",
            recurrence: "Regrows with use and updates.",
            confidence: .communityKnown),
        Recipe(
            id: "dev.cocoapods.cache",
            displayName: "CocoaPods cache",
            group: "Languages",
            paths: ["~/Library/Caches/CocoaPods", "~/.cocoapods/repos"],
            riskTier: .green, action: .quarantine,
            explanation: "Downloaded pod specs and cached pod sources.",
            impact: "Re-downloaded on the next `pod install`.",
            recurrence: "Grows with pod usage.",
            confidence: .communityKnown),
        Recipe(
            id: "dev.flutter.pubcache",
            displayName: "Dart/Flutter pub cache",
            group: "Languages",
            paths: ["~/.pub-cache"],
            riskTier: .green, action: .quarantine,
            explanation: "Downloaded Dart/Flutter packages.",
            impact: "Re-downloaded on the next `pub get`/`flutter pub get`.",
            recurrence: "Grows as you add packages.",
            confidence: .communityKnown),
        Recipe(
            id: "dev.nuget.packages",
            displayName: "NuGet package cache",
            group: "Languages",
            paths: ["~/.nuget/packages"],
            riskTier: .green, action: .quarantine,
            explanation: "Downloaded .NET NuGet packages.",
            impact: "Re-downloaded on the next restore.",
            recurrence: "Grows with .NET builds.",
            confidence: .communityKnown),
        // ── Gaming ──────────────────────────────────────────────────
        Recipe(
            id: "game.unity.cache",
            displayName: "Unity caches & Asset Store downloads",
            group: "Gaming",
            paths: ["~/Library/Unity/cache", "~/Library/Unity/Asset Store-5.x"],
            riskTier: .yellow, requiresQuit: ["Unity", "Unity Hub"], action: .reviewOnly,
            explanation: "Unity's global package/asset caches and downloaded Asset Store packages.",
            impact: "Re-downloadable, but large Asset Store items may take a while to fetch again.",
            recurrence: "Grows as you import assets.",
            confidence: .communityKnown),
    ]
}
