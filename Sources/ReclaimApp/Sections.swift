import SwiftUI
import ReclaimCore

/// The one-and-only scan screen: scan everything, pre-select the safe wins,
/// clean with one click.
struct ScanView: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingCLI: SupportedCLI.Command?

    var body: some View {
        Group {
            if model.scanning {
                scanning
            } else if model.hasScanned {
                results
            } else {
                welcome
            }
        }
        .navigationTitle("Reclaim")
        .toolbar {
            if model.hasScanned {
                Button { model.runEverything() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(model.scanning)
            }
        }
        .sheet(item: $model.openCluster) { cluster in
            ClusterDetailView(cluster: cluster).environmentObject(model)
        }
        .confirmationDialog("Run this cleanup command?",
            isPresented: Binding(get: { pendingCLI != nil },
                                 set: { if !$0 { pendingCLI = nil } }),
            presenting: pendingCLI) { cmd in
            Button("Run  \(cmd.invocation)", role: .destructive) {
                model.runCLI(cmd); pendingCLI = nil
            }
            Button("Cancel", role: .cancel) { pendingCLI = nil }
        } message: { cmd in
            Text("Reclaim will run:\n\(cmd.invocation)\n\nThis uses the tool's own cleanup — safe and supported, but not reversible from Reclaim's quarantine.")
        }
    }

    // MARK: States

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 52)).foregroundStyle(.tint)
            Text("Your Mac is not full.\nYour tools are messy.")
                .font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
            Text("One scan checks your caches, developer tools, leftovers from deleted apps, and personal pile-ups — then shows you exactly what's safe to clear.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            Button {
                model.runEverything()
            } label: {
                Text("Scan My Mac").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            Text("Read-only. Nothing is changed until you choose to clean.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanning: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Scanning your Mac…").font(.headline)
            Text("Caches · developer tools · app leftovers · personal files")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Results

    private var results: some View {
        VStack(spacing: 0) {
            List {
                Section { hero.listRowSeparator(.hidden) }

                let safe = model.items.filter(\.safe)
                // "Review" now includes anything blocked by a running app — its
                // reclaimable value shouldn't hide in a side section. Only truly
                // protected (Red) items are split out.
                let review = model.items.filter { !$0.safe && $0.tier != .red }
                let protectedItems = model.items.filter { $0.tier == .red }

                if !safe.isEmpty {
                    Section {
                        ForEach(safe) { row($0) }
                    } header: { groupHeader("Safe to clean", "Regenerable caches, re-downloadable data, and leftovers from deleted apps — all reversible. Pre-selected.", safe) }
                }
                if !model.cliItems.isEmpty {
                    Section {
                        ForEach(model.cliItems) { cliRow($0) }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Clean with the tool's own command").font(.headline)
                                Spacer()
                                Text(Fmt.bytes(model.cliItems.reduce(0) { $0 + $1.bytes }))
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text("Caches cleaned by their own tool (npm, brew…) — the safe, supported way. Not reversible via quarantine.")
                                .font(.caption).foregroundStyle(.secondary).textCase(nil)
                        }
                        .padding(.vertical, 2)
                    }
                }
                if !model.clusters.isEmpty {
                    Section {
                        ForEach(model.clusters) { clusterRow($0) }
                    } header: { Text("Pile-ups worth a look") }
                        footer: { Text("Groups of personal files. Click one to browse and pick what to remove.") }
                }
                if !review.isEmpty {
                    Section {
                        ForEach(review) { row($0) }
                    } header: { groupHeader("More to review", "History and personal files — plus anything an open app is using. We explain each; you decide.", review) }
                        footer: { Text("Rows with a pause icon are in use by an app you have open — quit it and hit Rescan to clean them. Reclaim won't clear data out from under a running app.") }
                }
                if !protectedItems.isEmpty {
                    Section {
                        ForEach(protectedItems) { row($0) }
                    } header: { Text("Protected by macOS") }
                        footer: { Text("System data Reclaim reports but never removes.") }
                }
            }
            .listStyle(.inset)
            cleanBar
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                StatCard(title: "Ready to reclaim", value: Fmt.bytes(model.safeReclaimBytes),
                         subtitle: "Safe · reversible", color: .green)
                StatCard(title: "More to review", value: Fmt.bytes(model.reviewBytes),
                         subtitle: "History & personal", color: .orange)
                StatCard(title: "Free space", value: Fmt.bytes(model.freeBytes),
                         subtitle: "of \(Fmt.bytes(model.totalBytes))", color: .blue)
            }
            if let r = model.scanReport, r.snapshots.mayPinDeletedBlocks {
                Label("\(r.snapshots.count) APFS snapshot(s) present — freed space may take up to ~24h to show.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var cleanBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.selected.count) selected").font(.callout.weight(.medium))
                Text(Fmt.bytes(model.selectedBytes)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.cleanSelected()
            } label: {
                Text("Reclaim \(Fmt.bytes(model.selectedBytes))")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(model.selected.isEmpty || model.busy != nil)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: Rows

    private func groupHeader(_ title: String, _ subtitle: String, _ items: [AppModel.CleanItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(Fmt.bytes(items.reduce(0) { $0 + $1.bytes })).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary).textCase(nil)
        }
        .padding(.vertical, 2)
    }

    private func row(_ item: AppModel.CleanItem) -> some View {
        CleanRow(item: item,
                 isOn: Binding(get: { model.selected.contains(item.id) },
                               set: { model.toggle(item.id, $0) }))
    }

    private func cliRow(_ item: AppModel.CLIItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal").foregroundStyle(.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).fontWeight(.medium).lineLimit(1)
                Text(item.command.invocation).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Fmt.bytes(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
            Button("Clean") { pendingCLI = item.command }
                .buttonStyle(.bordered).disabled(model.busy != nil)
        }
        .padding(.vertical, 2)
    }

    private func clusterRow(_ c: Cluster) -> some View {
        Button { model.openCluster = c } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.tint).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(c.category) in \(c.directory)").fontWeight(.medium)
                        Spacer()
                        Text(Fmt.bytes(c.totalBytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(c.rationale).font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

struct CleanRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ai: AISettings
    let item: AppModel.CleanItem
    @Binding var isOn: Bool
    @State private var expanded = false
    @State private var browse: MyMacDrill?
    @State private var loadingBrowse = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if item.selectable {
                Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.checkbox)
            } else {
                Image(systemName: item.tier == .red ? "lock.fill" : "pause.circle")
                    .foregroundStyle(.secondary).frame(width: 16).padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle().fill(item.tier.color).frame(width: 7, height: 7)
                    Text(item.name).fontWeight(.medium).lineLimit(1)
                    ForEach(item.blockingApps, id: \.self) { AppChip(name: $0) }
                    Spacer()
                    Text(Fmt.bytes(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    if ai.isReady { AISparkButton { model.explainItem(item) } }
                    if item.isDirectory {
                        Button { openBrowser() } label: {
                            if loadingBrowse {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "rectangle.split.3x3").font(.caption)
                            }
                        }
                        .buttonStyle(.borderless)
                        .help("Browse what's inside — previews, sizes, and dates")
                        .disabled(loadingBrowse)
                    }
                }
                if expanded {
                    Text(item.detail).font(.callout).foregroundStyle(.secondary)
                    if !item.impact.isEmpty {
                        Text("If you remove it: \(item.impact)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !item.recurrence.isEmpty {
                        Text("Comes back? \(item.recurrence)")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(item.id).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                HStack(spacing: 14) {
                    Button(expanded ? "Less" : "Why?") { expanded.toggle() }
                        .buttonStyle(.link).font(.caption)
                    if item.isDirectory {
                        Button("Browse contents") { openBrowser() }
                            .buttonStyle(.link).font(.caption).disabled(loadingBrowse)
                    }
                    if !item.selectable && !item.blockingApps.isEmpty {
                        Button("Quit \(item.blockingApps.joined(separator: " & ")) & Clean") {
                            model.quitAndClean(item)
                        }
                        .buttonStyle(.link).font(.caption).disabled(model.busy != nil)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .sheet(item: $browse) { d in
            CategoryBrowser(drill: d).environmentObject(model).environmentObject(ai)
        }
    }

    /// Load the real files inside this folder finding and open the rich browser
    /// (thumbnails, Quick Look, search) — never the raw UUID folder tree.
    private func openBrowser() {
        guard !loadingBrowse else { return }
        loadingBrowse = true
        Task {
            let files = await Task.detached(priority: .userInitiated) {
                DirLister.deepFiles(of: item.id)
            }.value
            loadingBrowse = false
            browse = MyMacDrill(
                id: "finding", name: item.name, symbol: "folder",
                files: files, categoryBytes: item.bytes, tier: item.tier, source: item.source)
        }
    }
}
