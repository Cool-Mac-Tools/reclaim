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
        List {
            Section { verdict(h).listRowSeparator(.hidden) }
            Section { statRow(h).listRowSeparator(.hidden) }

            Section("Why it might be slow") {
                ForEach(activity.diagnoses) { diagnosisRow($0) }
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
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                }
            } footer: {
                Text("Live view, refreshed every few seconds. CPU is recent usage — 100% is one full core. Quitting an app is graceful; it can still ask to save.")
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

    private func statRow(_ h: SystemHealth) -> some View {
        HStack(spacing: 12) {
            StatCard(title: "Memory", value: "\(Int(h.memoryUsedFraction * 100))%",
                     subtitle: "\(Fmt.bytes(h.usedMemoryBytes)) of \(Fmt.bytes(h.totalMemoryBytes))",
                     color: h.memoryUsedFraction > 0.9 ? .orange : .primary)
            StatCard(title: "Swap", value: Fmt.bytes(h.swapUsedBytes),
                     subtitle: h.swapUsedBytes > 0 ? "memory on disk" : "none — good",
                     color: h.swapUsedBytes > 3 * 1024 * 1024 * 1024 ? .orange : .primary)
            StatCard(title: "CPU load", value: String(format: "%.1f", h.loadAverage1),
                     subtitle: "across \(h.coreCount) cores",
                     color: h.loadAverage1 > Double(h.coreCount) * 1.5 ? .orange : .primary)
            StatCard(title: "Disk free", value: Fmt.bytes(h.freeDiskBytes),
                     subtitle: "of \(Fmt.bytes(h.totalDiskBytes))",
                     color: h.diskUsedFraction > 0.9 ? .orange : .blue)
        }
    }

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
        HStack(spacing: 10) {
            if let icon = activity.app(for: p.pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).lineLimit(1)
                Text("PID \(p.pid)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Int(p.cpuPercent))% CPU").font(.caption).monospacedDigit()
                    .foregroundStyle(p.cpuPercent > 80 ? .orange : .secondary)
                Text(Fmt.bytes(p.memoryBytes)).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            }
            if activity.app(for: p.pid) != nil {
                Button("Quit") { activity.quit(pid: p.pid) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
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
