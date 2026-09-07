import Foundation
import AppKit
import ApplicationServices
import CoreServices
import ReclaimCore

struct WorkspaceAppSnapshot: Sendable {
    let pid: Int32
    let name: String
    let bundleID: String
    let path: String?
    let focused: Bool
}

/// Each adapter returns observed metadata and its source; it never reads screen
/// pixels, terminal contents, password fields, or browser history databases.
enum WorkspaceSources {
    static func apps(_ apps: [WorkspaceAppSnapshot], health: SystemHealth) -> [WorkspaceObject] {
        apps.map { app in
            let processes = health.processes.filter {
                $0.pid == app.pid || (app.path.map { $0.hasSuffix(".app") && $0.count > 1 && $0 != "/" }
                    == true && $0.path.hasPrefix((app.path ?? "") + "/"))
            }
            let cpu = processes.reduce(0) { $0 + $1.cpuPercent }
            let memory = processes.reduce(0) { $0 + $1.memoryBytes }
            return WorkspaceObject(id: "app:\(app.pid)", kind: .app, title: app.name,
                detail: "\(String(format: "%.1f", cpu))% CPU · \(ByteFormatter.string(memory)) memory",
                source: "macOS running applications", state: app.focused ? .active : .idle,
                pid: app.pid, path: app.path, cpu: cpu, memory: memory,
                timestamp: health.sampledAt, focused: app.focused)
        }
    }
    static func windows(_ apps: [WorkspaceAppSnapshot]) -> [WorkspaceObject] {
        var objects: [WorkspaceObject] = []
        let deadline = Date().addingTimeInterval(1.2)
        for app in apps.prefix(40) {
            if Date() >= deadline { break }
            let element = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(element, 0.12)
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &raw) == .success,
                  let windows = raw as? [AXUIElement] else { continue }
            let terminal = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                            "com.mitchellh.ghostty"].contains(app.bundleID)
            for (index, window) in windows.prefix(8).enumerated() {
                if Date() >= deadline { break }
                AXUIElementSetMessagingTimeout(window, 0.08)
                func text(_ attribute: String) -> String? {
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success else { return nil }
                    return value as? String
                }
                guard let title = text(kAXTitleAttribute), !title.isEmpty else { continue }
                let document = text(kAXDocumentAttribute).flatMap(URL.init(string:))
                let path = document?.isFileURL == true ? document?.path : nil
                objects.append(WorkspaceObject(id: "window:\(app.pid):\(index)",
                    kind: terminal ? .terminal : (path != nil ? .file : .app),
                    title: String(title.prefix(160)), detail: "Window in \(app.name)",
                    source: "Accessibility window metadata", pid: app.pid, path: path))
            }
        }
        return objects
    }
    struct BrowserResult: Sendable {
        var objects: [WorkspaceObject] = []
        var status: [String: String] = [:]
    }
    static func tabs(_ enabled: Set<String>, running: [WorkspaceAppSnapshot]) -> BrowserResult {
        var result = BrowserResult()
        // Fixed scripts for explicitly connected browsers. User content is returned
        // as Apple event lists, never interpolated into executable AppleScript.
        for id in enabled.sorted() {
            guard running.contains(where: { $0.bundleID == id }) else {
                result.status[id] = "Browser is closed"; continue
            }
            let safari = id == "com.apple.Safari"
            guard safari || id == "com.google.Chrome" else { continue }
            let script = """
            with timeout of 3 seconds
                tell application id "\(id)"
                    set foundTabs to {}
                    repeat with w in windows
                        repeat with t in tabs of w
                            if (count of foundTabs) ≥ 80 then exit repeat
                            set end of foundTabs to {\(safari ? "name" : "title") of t, URL of t, id of w as text, \(safari ? "index" : "id") of t as text}
                        end repeat
                        if (count of foundTabs) ≥ 80 then exit repeat
                    end repeat
                    return foundTabs
                end tell
            end timeout
            """
            var error: NSDictionary?
            let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                let number = error[NSAppleScript.errorNumber] as? Int ?? 0
                result.status[id] = number == -1743 ? "Allow Reclaim in Privacy → Automation" : "Browser unavailable; reconnect to retry"
                continue
            }
            guard let descriptor else { result.status[id] = "No tab data"; continue }
            if descriptor.numberOfItems > 0 {
                for i in 1...min(80, descriptor.numberOfItems) {
                    guard let row = descriptor.atIndex(i), let title = row.atIndex(1)?.stringValue,
                          let rawURL = row.atIndex(2)?.stringValue else { continue }
                    let window = row.atIndex(3)?.stringValue ?? "0"
                    let index = row.atIndex(4)?.stringValue ?? String(i)
                    let host = URL(string: rawURL)?.host ?? "Local browser page"
                    result.objects.append(WorkspaceObject(id: "tab:\(id):\(window):\(index)", kind: .tab,
                        title: String(title.prefix(160)), detail: host,
                        source: safari ? "Safari connection" : "Chrome connection", url: rawURL))
                }
            }
            result.status[id] = "Connected · up to 80 tabs · refreshes every 12 seconds"
        }
        return result
    }
}

/// FSEvents reports saves recursively; no file contents or periodic directory walks.
/// The watcher owns the stream until stop/deinit, and callbacks only carry strings.
final class WorkspaceFileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.reclaim.workspace.files", qos: .utility)
    private let receive: @Sendable ([String]) -> Void
    init(url: URL, receive: @escaping @Sendable ([String]) -> Void) {
        self.receive = receive
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let owner = Unmanaged<WorkspaceFileWatcher>.fromOpaque(info).takeUnretainedValue()
            let values = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changed: [String] = []
            for i in 0..<min(count, values.count) {
                let flag = flags[i]
                guard flag & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 else { continue }
                let changes = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCreated
                    | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
                guard flag & changes != 0 else { continue }
                let parts = values[i].split(separator: "/")
                let excluded: Set<Substring> = [".git", ".build", "node_modules", ".next", "DerivedData", ".reclaim"]
                guard parts.allSatisfy({ !excluded.contains($0) }) else { continue }
                changed.append(values[i])
            }
            if !changed.isEmpty { owner.receive(Array(Set(changed)).sorted()) }
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
        UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }
    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            // Drain callbacks before releasing the unretained context.
            queue.sync {}
            FSEventStreamRelease(stream)
        }
    }
}
