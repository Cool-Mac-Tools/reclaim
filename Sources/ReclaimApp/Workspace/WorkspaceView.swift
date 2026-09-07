import SwiftUI
import ReclaimCore

struct WorkspaceView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var workspace = WorkspaceModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var objects: [WorkspaceObject] {
        var rows = workspace.visible
        if workspace.filter == nil || workspace.filter == .task {
            if let busy = app.busy {
                rows.append(WorkspaceObject(id: "reclaim:operation", kind: .task, title: busy,
                    detail: "Reclaim operation in progress", source: "Reclaim", state: .active))
            } else if app.mapping || app.scanning {
                rows.append(WorkspaceObject(id: "reclaim:scan", kind: .task, title: "Scanning your Mac",
                    detail: "\(app.mapProgressFiles.formatted()) files measured", source: "Reclaim", state: .active))
            }
        }
        return rows
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.07))
            filters
            HStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    WorkspaceScene(objects: objects, selectedID: workspace.selectedID, focus: workspace.filter,
                        resetToken: workspace.resetCamera, reduceMotion: reduceMotion,
                        select: { workspace.selectedID = $0 })
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Drag to orbit · Scroll to zoom · Click to inspect")
                        Text("Up to 12 objects per zone · All objects in the list")
                            .foregroundStyle(.white.opacity(0.38))
                    }
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                    .padding(12).background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    .padding(16).allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                inspector.frame(width: 258)
            }
            .frame(maxHeight: .infinity)
            activityStrip
        }
        .background(Color(red: 0.045, green: 0.06, blue: 0.085))
        .preferredColorScheme(.dark)
        .navigationTitle("Workspace")
        .toolbar {
            Button { app.section = .myMac } label: { Label("Storage map", systemImage: "internaldrive") }
            Button { app.section = .activity } label: { Label("Activity", systemImage: "speedometer") }
        }
        .onAppear { workspace.start() }
        .onDisappear { workspace.stop() }
        .sheet(isPresented: $workspace.showConnections) { connections }
    }
    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Circle().fill(workspace.paused ? Color.orange : .mint).frame(width: 6, height: 6)
                    Text(workspace.paused ? "PAUSED" : workspace.sampledAt == nil ? "CONNECTING" : "LIVE WORKSPACE")
                        .font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(.white.opacity(0.6))
                }
                Text("Your Mac, in motion.").font(.system(size: 24, weight: .semibold, design: .rounded))
            }
            Spacer(minLength: 4)
            Button {
                workspace.paused.toggle()
                if !workspace.paused { workspace.refresh() }
            } label: { Image(systemName: workspace.paused ? "play.fill" : "pause.fill") }
            .help(workspace.paused ? "Resume live updates" : "Pause live updates")
            Button { workspace.resetCamera += 1 } label: { Image(systemName: "viewfinder") }.help("Reset camera")
            Button("Connections", systemImage: "point.3.connected.trianglepath.dotted") { workspace.showConnections = true }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 22).padding(.vertical, 18)
    }
    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                chip(nil, title: "Everything", symbol: "square.grid.2x2")
                ForEach(WorkspaceKind.allCases, id: \.self) { kind in
                    chip(kind, title: kind.title, symbol: kind.symbol)
                }
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }
    }
    private func chip(_ kind: WorkspaceKind?, title: String, symbol: String) -> some View {
        let chosen = workspace.filter == kind
        return Button { workspace.filter = kind } label: {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(chosen ? (kind?.color ?? .white).opacity(0.18) : .white.opacity(0.035), in: Capsule())
                .overlay(Capsule().strokeBorder(chosen ? (kind?.color ?? .white).opacity(0.4) : .white.opacity(0.08)))
                .foregroundStyle(chosen ? kind?.color ?? .white : .white.opacity(0.6))
        }.buttonStyle(.plain)
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let object = objects.first(where: { $0.id == workspace.selectedID }) {
                selectedCard(object)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("WORKSPACE PULSE").font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(.white.opacity(0.45))
                    if let health = workspace.health {
                        metric("Memory", value: Fmt.bytes(health.usedMemoryBytes), fraction: health.memoryUsedFraction, color: .purple)
                        metric("CPU load", value: String(format: "%.1f / %d cores", health.loadAverage1, health.coreCount),
                               fraction: health.loadAverage1 / Double(max(1, health.coreCount)), color: .mint)
                        metric("Storage used", value: Fmt.bytes(health.totalDiskBytes - health.freeDiskBytes),
                               fraction: health.diskUsedFraction, color: .blue)
                    } else { ProgressView("Reading live activity…").font(.caption) }
                    Text("Select an object to see where it comes from and what it’s doing.")
                        .font(.caption).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                }.padding(18)
            }
            Divider().overlay(.white.opacity(0.06))
            HStack {
                Text("OBJECTS").font(.system(size: 10, weight: .bold)).tracking(1.4)
                Spacer(); Text("\(objects.count)").font(.caption.monospacedDigit())
            }.foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 16).padding(.top, 14)
            TextField("Find an object", text: $workspace.search).textFieldStyle(.roundedBorder).font(.caption).padding(12)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(objects.sorted { $0.kind == $1.kind ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.kind.rawValue < $1.kind.rawValue }) { object in
                        Button { workspace.selectedID = object.id } label: {
                            HStack(spacing: 9) {
                                Image(systemName: object.kind.symbol).foregroundStyle(object.kind.color).frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(object.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    Text(object.detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if object.focused { Circle().fill(.mint).frame(width: 5, height: 5) }
                            }
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(workspace.selectedID == object.id ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).accessibilityLabel("\(object.kind.title): \(object.title). \(object.detail)")
                    }
                    if objects.isEmpty {
                        Text("No objects in this view yet. Connect a source to see its activity.")
                            .font(.caption).foregroundStyle(.secondary).padding()
                    }
                }.padding(.horizontal, 7)
            }
        }.background(.white.opacity(0.025))
    }
    private func selectedCard(_ object: WorkspaceObject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: object.kind.symbol).font(.title2).foregroundStyle(object.kind.color)
                Spacer()
                Button { workspace.selectedID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            Text(object.title).font(.headline).lineLimit(3)
            Text(object.detail).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            Label(object.source, systemImage: "checkmark.shield").font(.system(size: 10)).foregroundStyle(object.kind.color)
            if let date = object.timestamp { Text(date, style: .relative).font(.caption2).foregroundStyle(.secondary) }
            if object.kind == .storage {
                Button("Explore storage", systemImage: "arrow.up.right") { app.section = .myMac }.controlSize(.small)
                if let map = app.mapReport {
                    Text("Map updated \(map.scannedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                    ForEach(Array(map.categories.prefix(3)), id: \.id) { category in
                        HStack { Text(category.name); Spacer(); Text(Fmt.bytes(category.bytes)) }.font(.caption2)
                    }
                }
            } else if object.pid != nil || object.path != nil || object.url != nil {
                Button(object.pid != nil ? "Switch to app" : object.path != nil ? "Reveal in Finder" : "Open page",
                       systemImage: "arrow.up.right") { workspace.open(object) }.controlSize(.small)
            }
        }.padding(18)
    }
    private func metric(_ title: String, value: String, fraction: Double, color: Color) -> some View {
        VStack(spacing: 5) {
            HStack { Text(title).foregroundStyle(.white.opacity(0.55)); Spacer(); Text(value).monospacedDigit() }
                .font(.system(size: 10))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07))
                    Capsule().fill(color.opacity(0.7)).frame(width: proxy.size.width * max(0, min(1, fraction)))
                }
            }.frame(height: 4)
        }.padding(.vertical, 3)
    }
    private var activityStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ACTIVITY STREAM").font(.system(size: 10, weight: .bold)).tracking(1.4)
                Spacer()
                if let date = workspace.sampledAt {
                    Text("Sampled \(date.formatted(date: .omitted, time: .standard)) · every 3 seconds")
                        .font(.system(size: 10)).monospacedDigit()
                }
            }.foregroundStyle(.white.opacity(0.4))
            if workspace.recentEvents.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path").foregroundStyle(.mint.opacity(0.6))
                    Text("Watch a folder or connect a tool to see file edits, agent actions, and task progress here.")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button("Connect", action: { workspace.showConnections = true }).controlSize(.small)
                }.padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(workspace.recentEvents.prefix(12))) { event in
                            VStack(alignment: .leading, spacing: 5) {
                                Label(event.title, systemImage: event.kind.symbol).font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(event.kind.color).lineLimit(1)
                                Text(event.detail.isEmpty ? event.state.rawValue : event.detail).font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary)
                            }.frame(width: 200, alignment: .leading).padding(10)
                                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 13).background(.black.opacity(0.14))
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Connect your workspace").font(.title2.weight(.semibold)); Spacer(); Button("Done") { workspace.showConnections = false } }
            Text("All workspace data stays on this Mac. Connections read metadata; they do not capture your screen or terminal contents.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Section("Apps, windows & terminals") {
                    Label("Running apps and system activity are connected", systemImage: "checkmark.circle.fill").foregroundStyle(.mint)
                    HStack {
                        Text(workspace.accessibility ? "Window details connected" : "Allow Accessibility to read window titles and open document paths")
                        Spacer()
                        Button("Enable window details") { workspace.enableAccessibility() }
                    }
                }
                Section("Browser tabs") {
                    browserToggle("Safari", id: "com.apple.Safari")
                    browserToggle("Google Chrome", id: "com.google.Chrome")
                    Text("macOS asks for Automation access when you connect a browser. Turn off a connection to remove its tab data. Connections reset when you leave Workspace.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Files & code edits") {
                    if let folder = workspace.watchedFolder {
                        Text(folder).font(.caption).textSelection(.enabled)
                        Button("Disconnect folder") { workspace.disconnectFolder() }
                    }
                    Button("Choose workspace folder…") { workspace.chooseFolder() }
                    Text("Reports saved file changes recursively. Build outputs and Git internals are excluded. Unsaved editor buffers are not observed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Agent actions & tasks") {
                    Text("Local tools can report progress using reclaim workspace-event. An active report becomes idle after 60 seconds without an update.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(workspace.eventPath).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    Button("Copy example command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("reclaim workspace-event --kind task --id build --title 'Build app' --state active", forType: .string)
                    }
                }
            }.formStyle(.grouped)
        }.padding(24).frame(width: 650, height: 650).preferredColorScheme(.dark)
    }
    private func browserToggle(_ title: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: Binding(get: { workspace.browserConnected(id) }, set: { workspace.connectBrowser(id, enabled: $0) }))
            if let status = workspace.browserStatus[id] { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
