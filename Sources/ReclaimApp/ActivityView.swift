import SwiftUI
import AppKit
import ReclaimCore

/// Owns the live system-health sampling for the Activity tab. Samples off the
/// main thread on a gentle timer while the tab is visible, and maps process ids
/// to their GUI app (for an icon and a graceful Quit). Read-only.
@MainActor
final class ActivityModel: ObservableObject {
    @Published var health: SystemHealth?
    @Published var diagnoses: [Diagnosis] = []
    @Published var loading = false
    /// pid → GUI app, for icons and quit. Non-GUI processes simply aren't here.
    @Published private(set) var apps: [Int32: NSRunningApplication] = [:]

    private let monitor = SystemMonitor()
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        if health == nil { loading = true }
        // Snapshot GUI apps on the main actor (AppKit), sample stats off-main.
        let appMap = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWithFirst: ())
        Task {
            let h = await Task.detached(priority: .userInitiated) { [monitor] in
                let s = monitor.sample()
                return (s, monitor.diagnose(s))
            }.value
            self.health = h.0
            self.diagnoses = h.1
            self.apps = appMap
            self.loading = false
        }
    }

    func app(for pid: Int32) -> NSRunningApplication? { apps[pid] }

    /// Gracefully quit a GUI app by pid (it can still prompt to save). We only
    /// offer this for real apps we can resolve — never a blind `kill`.
    func quit(pid: Int32) {
        apps[pid]?.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
    }
}

private extension Dictionary {
    /// Build a dict from pairs, keeping the FIRST value on a key collision
    /// (several helper processes can momentarily share… they won't, but be safe).
    init(_ pairs: [(Key, Value)], uniquingKeysWithFirst: ()) {
        self.init(pairs, uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - View

/// "Activity" — what's running and, in plain language, why the Mac might feel
/// slow. Read-only diagnostics; the one actionable path (low disk) hands off to
/// the Reclaim tab.
struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var activity = ActivityModel()
    @State private var sort: ProcessSort = .cpu

    enum ProcessSort: String, CaseIterable, Identifiable {
        case cpu = "CPU", memory = "Memory"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if let h = activity.health {
                results(h)
            } else {
                loading
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            Button { model.section = .workspace } label: { Label("3D workspace", systemImage: "cube.transparent") }
            if activity.health != nil {
                Button { activity.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .onAppear { activity.start() }
        .onDisappear { activity.stop() }
    }

    private var loading: some View {
        VStack(spacing: 14) {
            Image(systemName: "speedometer").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Checking what's running…").font(.title3.weight(.semibold))
            ProgressView().controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func results(_ h: SystemHealth) -> some View {
        let worst = activity.diagnoses.first?.severity ?? .ok
        let issues = activity.diagnoses.filter { $0.severity != .ok }
        return List {
            Section { verdict(h).listRowSeparator(.hidden) }
            Section { meters(h).listRowSeparator(.hidden) }
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))

            if worst != .ok {
                Section("Why it might be slow") {
                    ForEach(issues) { diagnosisRow($0) }
                }
            }

            Section {
                ForEach(topProcesses(h)) { processRow($0, total: h.totalMemoryBytes) }
            } header: {
                HStack {
                    Text("What's using your Mac")
                    Spacer()
                    Picker("Sort", selection: $sort) {
                        ForEach(ProcessSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }
            } footer: {
                Text("Live — refreshes every few seconds. CPU is recent usage; 100% is one full core. Quitting is graceful.")
                    .font(.caption).foregroundStyle(.secondary).textCase(nil)
            }
        }
        .listStyle(.inset)
    }

    // MARK: Verdict

    private func verdict(_ h: SystemHealth) -> some View {
        let worst = activity.diagnoses.first?.severity ?? .ok
        return HStack(spacing: 14) {
            Image(systemName: worst == .ok ? "checkmark.seal.fill" : "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 30)).foregroundStyle(severityColor(worst))
            VStack(alignment: .leading, spacing: 3) {
                Text(headline(worst)).font(.title3.weight(.semibold))
                Text("Up \(uptime(h.uptimeSeconds)) · \(h.processes.count) processes running")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(severityColor(worst).opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func headline(_ s: Diagnosis.Severity) -> String {
        switch s {
        case .ok:       "Your Mac looks healthy"
        case .info:     "A few things worth a look"
        case .warning:  "Here's what's slowing your Mac"
        case .critical: "Your Mac needs attention"
        }
    }

    private func meters(_ h: SystemHealth) -> some View {
        let memF = h.memoryUsedFraction
        let cpuF = min(1, h.loadAverage1 / Double(max(1, h.coreCount)))
        let diskF = h.diskUsedFraction
        return HStack(spacing: 12) {
            MeterCard(title: "Memory", value: "\(Int((memF * 100).rounded()))%",
                      caption: memoryCaption(h), valueColor: valueColor(memF)) {
                UsageBar(fraction: memF, color: barColor(memF))
            }
            MeterCard(title: "CPU load", value: String(format: "%.1f", h.loadAverage1),
                      caption: cpuCaption(h), valueColor: valueColor(cpuF)) {
                UsageBar(fraction: cpuF, color: barColor(cpuF))
            }
            MeterCard(title: "Storage", value: "\(Int((diskF * 100).rounded()))%",
                      caption: "\(Fmt.bytes(h.freeDiskBytes)) free of \(Fmt.bytes(h.totalDiskBytes))",
                      valueColor: valueColor(diskF)) {
                UsageBar(fraction: diskF, color: barColor(diskF))
            }
        }
    }

    private func memoryCaption(_ h: SystemHealth) -> String {
        var s = "\(Fmt.bytes(h.usedMemoryBytes)) of \(Fmt.bytes(h.totalMemoryBytes))"
        if h.swapUsedBytes > 0 { s += " · \(Fmt.bytes(h.swapUsedBytes)) swap" }
        return s
    }

    private func cpuCaption(_ h: SystemHealth) -> String {
        var s = "across \(h.coreCount) cores"
        switch h.thermal {
        case .fair:     s += " · warm"
        case .serious:  s += " · running hot"
        case .critical: s += " · very hot"
        case .nominal:  break
        }
        return s
    }

    /// Shared pressure color ramp used by the meter bars + values, so calm is
    /// blue, busy is amber, and critical is red — everywhere.
    private func barColor(_ f: Double) -> Color { f >= 0.9 ? .red : (f >= 0.75 ? .orange : .blue) }
    private func valueColor(_ f: Double) -> Color { f >= 0.9 ? .red : (f >= 0.75 ? .orange : .primary) }

    // MARK: Rows

    @ViewBuilder private func diagnosisRow(_ d: Diagnosis) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: d.symbol)
                .foregroundStyle(severityColor(d.severity)).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(d.title).fontWeight(.medium)
                Text(d.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if d.reclaimActionable {
                    Button("Reclaim space") { model.section = .scan }
                        .buttonStyle(.borderedProminent).controlSize(.small).padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private func processRow(_ p: RunningProcess, total: Int64) -> some View {
        let byCPU = sort == .cpu
        // Honest, absolute fractions: CPU vs one core, memory vs total RAM.
        let fraction = byCPU ? min(1, p.cpuPercent / 100) : Double(p.memoryBytes) / Double(max(1, total))
        let hot = byCPU && p.cpuPercent > 80
        let barColor: Color = byCPU ? (hot ? .red : .orange) : .blue
        let primary = byCPU ? "\(Int(p.cpuPercent.rounded()))%" : Fmt.bytes(p.memoryBytes)
        let secondary = byCPU ? Fmt.bytes(p.memoryBytes) : "\(Int(p.cpuPercent.rounded()))% CPU"

        return HStack(spacing: 11) {
            if let icon = activity.app(for: p.pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            } else {
                Image(systemName: "gearshape.2")
                    .foregroundStyle(.secondary).frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(p.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(primary).font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(hot ? .red : .primary)
                }
                HStack(spacing: 8) {
                    UsageBar(fraction: fraction, color: barColor, height: 6)
                    Text(secondary).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                        .frame(width: 70, alignment: .trailing)
                }
            }
            if activity.app(for: p.pid) != nil {
                Button("Quit") { activity.quit(pid: p.pid) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Helpers

    private func topProcesses(_ h: SystemHealth) -> [RunningProcess] {
        let sorted = sort == .cpu
            ? h.processes.sorted { $0.cpuPercent > $1.cpuPercent }
            : h.processes.sorted { $0.memoryBytes > $1.memoryBytes }
        return Array(sorted.prefix(14))
    }

    private func severityColor(_ s: Diagnosis.Severity) -> Color {
        switch s {
        case .ok:       .green
        case .info:     .blue
        case .warning:  .orange
        case .critical: .red
        }
    }

    private func uptime(_ seconds: Double) -> String {
        let d = Int(seconds) / 86400, h = (Int(seconds) % 86400) / 3600, m = (Int(seconds) % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - Activity bars

/// A rounded usage bar with a track — the visual backbone of the Activity tab's
/// meters and process rows. Animates as live samples come in.
struct UsageBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                Capsule().fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: fraction)
    }
}

/// A compact metric card: label, big value, a usage bar, and a caption.
struct MeterCard<Bar: View>: View {
    let title: String
    let value: String
    let caption: String
    var valueColor: Color = .primary
    @ViewBuilder var bar: () -> Bar

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded))
                .foregroundStyle(valueColor).contentTransition(.numericText())
            bar()
            Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }
}
