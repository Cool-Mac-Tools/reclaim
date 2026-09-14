import SwiftUI
import AppKit
@preconcurrency import ApplicationServices
import ReclaimCore

struct WorkspaceObject: Identifiable, Equatable, Sendable {
    let id: String
    let kind: WorkspaceKind
    var title: String
    var detail: String
    var source: String
    var state: WorkspaceEvent.State = .idle
    var pid: Int32?
    var path: String?
    var url: String?
    var cpu: Double = 0
    var memory: Int64 = 0
    var timestamp: Date?
    var focused = false
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var objects: [WorkspaceObject] = []
    @Published private(set) var health: SystemHealth?
    @Published private(set) var sampledAt: Date?
    @Published private(set) var recentEvents: [WorkspaceEvent] = []
    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var browserStatus: [String: String] = [:]
    @Published private(set) var watchedFolder: String?
    @Published private(set) var folderStatus = ""
    @Published var paused = false
    @Published var selectedID: String?
    @Published var filter: WorkspaceKind?
    @Published var search = ""
    @Published var showConnections = false
    @Published var resetCamera = 0
    private var timer: Timer?
    private var refreshing = false
    private var generation = 0
    private var browserTick = 0
    private var browserObjects: [WorkspaceObject] = []
    private var connectedBrowsers = Set(UserDefaults.standard.stringArray(forKey: "workspace.browsers") ?? [])
    private var observers: [NSObjectProtocol] = []
    private var pendingRefresh = false
    private var watcher: WorkspaceFileWatcher?
    private var watcherGeneration = 0
    private var fileEvents: [WorkspaceEvent] = []
    private var appEvents: [WorkspaceEvent] = []
    private var feed = WorkspaceEventStore()

    var visible: [WorkspaceObject] {
        objects.filter { (filter == nil || $0.kind == filter) &&
            (search.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(search)) }
    }
    var selected: WorkspaceObject? { objects.first { $0.id == selectedID } }
    var eventPath: String { feed.url.path }

    func start() {
        guard timer == nil else { return }
        generation += 1
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        if let folder = watchedFolder ?? UserDefaults.standard.string(forKey: "workspace.folder") { watch(URL(fileURLWithPath: folder)) }
    }
    func stop() {
        generation += 1; timer?.invalidate(); timer = nil
        watcherGeneration += 1; watcher = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        browserObjects = []; browserStatus = [:]
    }
    func refresh() {
        guard !paused else { return }
        guard !refreshing else { pendingRefresh = true; return }
        refreshing = true; pendingRefresh = false
        let gen = generation
        accessibility = AXIsProcessTrusted()
        let permitted = accessibility
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let snapshots = apps.map { WorkspaceAppSnapshot(pid: $0.processIdentifier,
            name: $0.localizedName ?? "Application", bundleID: $0.bundleIdentifier ?? "",
            path: $0.bundleURL?.path, focused: $0.isActive) }
        let browsers = connectedBrowsers
        let shouldReadBrowsers = browserTick % 4 == 0
        browserTick += 1
        let eventStore = feed
        Task {
            let result = await Task.detached(priority: .utility) {
                let health = SystemMonitor().sample()
                var objects = WorkspaceSources.apps(snapshots, health: health)
                let windows = permitted ? WorkspaceSources.windows(snapshots.sorted { $0.focused && !$1.focused }) : []
                objects += windows
                objects += WorkspaceSources.tools(snapshots, health: health, windows: windows)
                let browser = shouldReadBrowsers ? WorkspaceSources.tabs(browsers, running: snapshots) : nil
                return (health, objects, eventStore.read(), browser)
            }.value
            refreshing = false
            defer { if pendingRefresh, timer != nil { refresh() } }
            guard gen == generation, !paused else { return }
            health = result.0
            if let browser = result.3 {
                browserObjects = browser.objects.filter { object in connectedBrowsers.contains { object.id.hasPrefix("tab:\($0):") } }
                browserStatus = browser.status.filter { connectedBrowsers.contains($0.key) }
            }
            let events = WorkspaceEvent.current(result.2 + fileEvents)
            var rows = result.1 + browserObjects
            rows += events.map { event in
                WorkspaceObject(id: "event:\(event.kind.rawValue):\(event.entityID)", kind: event.kind,
                    title: event.title, detail: event.detail,
                    source: event.entityID.hasPrefix("filesystem:") ? "Folder watcher" : "Local event feed",
                    state: event.state, path: event.path, timestamp: event.timestamp)
            }
            // Storage is measured by the same system probe as Activity. The full map
            // remains the authoritative breakdown and is opened from the inspector.
            rows.append(WorkspaceObject(id: "storage:startup", kind: .storage, title: "Startup disk",
                detail: "\(Fmt.bytes(result.0.freeDiskBytes)) free · \(Fmt.bytes(result.0.totalDiskBytes)) total",
                source: "Live volume measurement", timestamp: result.0.sampledAt))
            let previousApps = objects.filter { $0.id.hasPrefix("app:") }
            if !previousApps.isEmpty {
                let previousIDs = Set(previousApps.map(\.id))
                let currentApps = result.1.filter { $0.id.hasPrefix("app:") }
                let currentIDs = Set(currentApps.map(\.id))
                for item in currentApps where !previousIDs.contains(item.id) {
                    appEvents.insert(WorkspaceEvent(entityID: item.id, kind: .app, title: item.title,
                        detail: "Application opened", timestamp: result.0.sampledAt), at: 0)
                }
                for item in previousApps where !currentIDs.contains(item.id) {
                    appEvents.insert(WorkspaceEvent(entityID: item.id, kind: .app, title: item.title,
                        detail: "Application closed", state: .completed, timestamp: result.0.sampledAt), at: 0)
                }
                if let focused = currentApps.first(where: \.focused),
                   focused.id != previousApps.first(where: \.focused)?.id {
                    appEvents.insert(WorkspaceEvent(entityID: focused.id, kind: .app, title: focused.title,
                        detail: "Became the focused app", timestamp: result.0.sampledAt), at: 0)
                }
                appEvents = Array(appEvents.prefix(40))
            }
            let oldProcesses = objects.filter { $0.id.hasPrefix("process:") }
            let newProcesses = rows.filter { $0.id.hasPrefix("process:") }
            let oldIDs = Set(oldProcesses.map(\.id)), newIDs = Set(newProcesses.map(\.id))
            for process in newProcesses where !oldIDs.contains(process.id) {
                appEvents.insert(WorkspaceEvent(entityID: process.id, kind: process.kind, title: process.title,
                    detail: "Running process detected", timestamp: result.0.sampledAt), at: 0)
            }
            for process in oldProcesses where !newIDs.contains(process.id) {
                appEvents.insert(WorkspaceEvent(entityID: process.id, kind: process.kind, title: process.title,
                    detail: "Process exited", state: .completed, timestamp: result.0.sampledAt), at: 0)
            }
            appEvents = Array(appEvents.prefix(40))
            objects = rows
            recentEvents = Array((result.2 + fileEvents + appEvents).filter { $0.isValid && $0.timestamp <= Date() }
                .sorted { $0.timestamp > $1.timestamp }.prefix(30))
            sampledAt = result.0.sampledAt
            if let selectedID, !objects.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        }
    }
    func enableAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    func browserConnected(_ id: String) -> Bool { connectedBrowsers.contains(id) }
    func connectBrowser(_ id: String, enabled: Bool) {
        if enabled { connectedBrowsers.insert(id) } else {
            connectedBrowsers.remove(id)
            browserObjects.removeAll { $0.id.hasPrefix("tab:\(id):") }
            objects.removeAll { $0.id.hasPrefix("tab:\(id):") }
            browserStatus[id] = nil
        }
        UserDefaults.standard.set(Array(connectedBrowsers).sorted(), forKey: "workspace.browsers")
        browserTick = 0; refresh()
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Watch workspace"
        panel.message = "Show file saves in this folder. File contents are not read."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        watch(url)
    }
    func watch(_ url: URL) {
        watcherGeneration += 1
        let watchGeneration = watcherGeneration
        watcher = nil; watchedFolder = url.path
        UserDefaults.standard.set(url.path, forKey: "workspace.folder")
        fileEvents = []
        folderStatus = ""
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            folderStatus = "Folder unavailable — choose an accessible folder"; return
        }
        watcher = WorkspaceFileWatcher(url: url) { [weak self] paths in
            Task { @MainActor in
                guard let self, !self.paused, self.watcherGeneration == watchGeneration else { return }
                let now = Date()
                let recentPaths = Set(self.fileEvents.filter { now.timeIntervalSince($0.timestamp) < 2 }.compactMap(\.path))
                let events = paths.filter { !recentPaths.contains($0) }.prefix(40).map { path in
                    WorkspaceEvent(entityID: "filesystem:\(path)", kind: .file,
                        title: (path as NSString).lastPathComponent,
                        detail: "File changed · \((path as NSString).deletingLastPathComponent)",
                        timestamp: now, path: path)
                }
                guard !events.isEmpty else { return }
                self.fileEvents = Array((events + self.fileEvents).prefix(100))
                self.refresh()
            }
        }
        if watcher?.isActive != true { folderStatus = "Couldn’t start watching this folder" }
    }
    func disconnectFolder() {
        watcherGeneration += 1; watcher = nil; watchedFolder = nil; fileEvents = []
        UserDefaults.standard.removeObject(forKey: "workspace.folder")
        folderStatus = ""
        objects.removeAll { $0.source == "Folder watcher" }
        recentEvents.removeAll { $0.entityID.hasPrefix("filesystem:") }
        refresh()
    }
    func open(_ object: WorkspaceObject) {
        if let pid = object.pid { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) }
        else if let path = object.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        else if let raw = object.url, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }
}
