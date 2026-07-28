import SwiftUI
import ReclaimCore

// Reclaim Dev — SwiftUI dashboard prototype.
// Same ReclaimCore engine as the CLI; this is presentation only.
// Design language per plan §12: "a financial dashboard for storage,
// not a scary malware cleaner." No red theatrics, no fake urgency.

@main
struct ReclaimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var ai = AISettings.shared

    var body: some Scene {
        WindowGroup("Reclaim") {
            RootView()
                .environmentObject(model)
                .environmentObject(ai)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowStyle(.titleBar)
    }
}

/// Running from `swift run` (no app bundle): promote to a regular
/// foreground app so the window appears and takes focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // The packaged .app sets its Dock/Finder icon via Info.plist
        // (CFBundleIconFile = AppIcon). For `swift run` dev builds there's no
        // bundle, so fall back to the icns in Resources if it's alongside.
        if let icon = NSImage(contentsOfFile: "Resources/AppIcon.icns") {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class ScanModel: ObservableObject {
    @Published var report: ScanReport?
    @Published var scanning = false
    @Published var currentRecipe = ""

    func runScan() {
        guard !scanning else { return }
        scanning = true
        report = nil
        Task.detached(priority: .userInitiated) {
            let scanner = StorageScanner()
            let result = scanner.scan { name in
                Task { @MainActor [weak self] in self?.currentRecipe = name }
            }
            await MainActor.run { [weak self] in
                self?.report = result
                self?.scanning = false
            }
        }
    }
}
