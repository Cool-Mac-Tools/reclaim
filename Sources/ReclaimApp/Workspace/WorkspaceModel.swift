import SwiftUI
import AppKit
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

/// One sampler for Activity's list, insights and diagram. Switching views never
/// starts a second timer or produces a second set of resource measurements.
@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var health: SystemHealth?
    @Published private(set) var diagnoses: [Diagnosis] = []
    @Published private(set) var groups: [ActivityProcessGroup] = []
    @Published private(set) var apps: [String: NSRunningApplication] = [:]
    @Published var selectedID: String?
    @Published var resetCamera = 0
    @Published var paused = false
    private var timer: Timer?
    private var refreshing = false
    private var generation = 0
    private var sampleCount = 0

    var objects: [WorkspaceObject] {
        guard let health else { return [] }
        var rows = groups.map { group in
            let app = apps[group.id]
            return WorkspaceObject(id: group.id, kind: group.appPath == nil ? .task : .app,
                title: group.name,
                detail: "\(String(format: "%.1f", group.cpuPercent))% CPU · \(Fmt.bytes(group.memoryBytes)) · \(group.processes.count) process(es)",
                source: "Live process table · same sample as Activity", state: group.cpuPercent > 20 ? .active : .idle,
                pid: app?.processIdentifier, path: group.appPath,
                cpu: group.cpuPercent, memory: group.memoryBytes,
                timestamp: health.sampledAt, focused: app?.isActive == true)
        }
        rows.append(WorkspaceObject(id: "storage:startup", kind: .storage, title: "Your Mac",
            detail: "\(Fmt.bytes(health.freeDiskBytes)) disk free · \(health.processes.count) processes",
            source: "Live system measurement", timestamp: health.sampledAt))
        return rows
    }

    func start() {
        guard timer == nil else { return }
        generation += 1
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func stop() { generation += 1; timer?.invalidate(); timer = nil }
    func refresh() {
        guard !refreshing, !paused else { return }
        refreshing = true
        let gen = generation
        var appMap: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let path = app.bundleURL?.path { appMap[AppDiscovery.canonicalPath(path)] = app }
        }
        let previous = health
        let expensive = sampleCount % 20 == 0
        sampleCount += 1
        Task {
            let result = await Task.detached(priority: .utility) {
                let monitor = SystemMonitor()
                let health = monitor.sample(previous: expensive ? nil : previous)
                return (health, monitor.diagnose(health), ActivityProcessGroup.groups(health.processes))
            }.value
            refreshing = false
            guard gen == generation, !paused else { return }
            health = result.0; diagnoses = result.1; groups = result.2; apps = appMap
            if let selectedID, !objects.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        }
    }
    func quit(_ group: ActivityProcessGroup) {
        apps[group.id]?.terminate()
    }
    func open(_ object: WorkspaceObject) {
        if let pid = object.pid { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) }
        else if let path = object.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
}
