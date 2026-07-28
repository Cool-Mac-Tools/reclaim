import SwiftUI
import ReclaimCore

/// "My Mac" — an honest, whole-disk view of what's using space. Read-only for
/// now (cleanup lives in the Scan tab). Its headline reconciles exactly to the
/// disk's real used space, so it matches About This Mac.
struct MyMacView: View {
    @EnvironmentObject var model: AppModel
    @State private var drill: MyMacDrill?
    @State private var showDuplicates = false
    @State private var displayedCount: Double = 0   // smoothly tweened file counter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    // One scan feeds both pages: My Mac and the Reclaim suggestions.
    private var scanningNow: Bool { model.mapping || model.scanning }

    var body: some View {
        Group {
            if scanningNow && model.mapReport == nil {
                scanning
            } else if let report = model.mapReport {
                results(report)
            } else {
                welcome
            }
        }
        .navigationTitle("My Mac")
        .toolbar {
            if model.mapReport != nil {
                Button { model.runEverything() } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(scanningNow)
            }
        }
    }

    // MARK: States

    private var welcome: some View {
        SectionPrompt(
            icon: "internaldrive",
            title: "See everything on your Mac",
            message: "A complete picture of what's using your storage — apps, photos, "
                   + "documents, caches, and system data — measured against your disk's "
                   + "real capacity. Viewing only; nothing is changed.",
            actionTitle: "Scan My Mac",
            action: { model.runEverything() })
    }

    /// Which stage of the scan we're in, inferred from files-walked so far.
    private var scanStage: String {
        switch model.mapProgressFiles {
        case 0:            "Starting scan…"
        case ..<200_000:   "Reading your files…"
        case ..<800_000:   "Measuring apps, caches & media…"
        default:           "Reconciling with your disk & finding duplicates…"
        }
    }

    /// Fraction 0…1 for the bar, capped just below full until the scan actually
    /// finishes (the estimate can be off; we never want it to sit at 100%).
    private var scanFraction: Double {
        min(0.98, displayedCount / Double(max(1, model.expectedFileTotal)))
    }

    private var scanning: some View {
        VStack(spacing: 18) {
            Image(systemName: "internaldrive")
                .font(.system(size: 42)).foregroundStyle(.tint)
            Text("Scanning your Mac").font(.title3.weight(.semibold))
            ProgressView(value: scanFraction).progressViewStyle(.linear).frame(maxWidth: 300)
            VStack(spacing: 4) {
                Text(scanStage)
                    .font(.callout).foregroundStyle(.secondary)
                    .contentTransition(.opacity).animation(.default, value: scanStage)
                Text("\(Int(displayedCount).formatted()) files scanned")
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
            Text("This one's thorough — it walks your whole disk. Takes a bit longer than a quick scan.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .onAppear { displayedCount = 0 }
        .onReceive(ticker) { _ in
            let target = Double(model.mapProgressFiles)
            guard displayedCount < target else { return }
            if reduceMotion {
                displayedCount = target
            } else {
                // Ease toward the real count so the number races up smoothly
                // between the (every-5k-files) real updates.
                displayedCount = min(target, displayedCount + max(600, (target - displayedCount) * 0.12))
            }
        }
    }

    // MARK: Results

    private func results(_ report: MacStorageReport) -> some View {
        List {
            Section {
                header(report).listRowSeparator(.hidden)
            }
            if !report.duplicates.isEmpty {
                Section {
                    duplicatesCard(report)
                }
            }
            Section {
                ForEach(report.categories) { row($0, report: report) }
            } header: {
                Text("Where your space goes")
            } footer: {
                footnote(report)
            }
        }
        .listStyle(.inset)
        .overlay(alignment: .top) {
            if scanningNow { refreshingChip }
        }
        .sheet(item: $drill) { d in
            CategoryBrowser(drill: d).environmentObject(model).environmentObject(AISettings.shared)
        }
        .sheet(isPresented: $showDuplicates) {
            DuplicatesView(groups: model.mapReport?.duplicates ?? []).environmentObject(model)
        }
    }

    /// A highlighted entry point to the duplicate finder, above the category map.
    private func duplicatesCard(_ report: MacStorageReport) -> some View {
        Button { showDuplicates = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundStyle(.tint).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Duplicate files").fontWeight(.semibold)
                    Text("\(report.duplicates.count) group\(report.duplicates.count == 1 ? "" : "s") of identical files — keep one, reclaim the rest")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Fmt.bytes(report.duplicateReclaimableBytes))
                    .monospacedDigit().foregroundStyle(.green)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private func header(_ report: MacStorageReport) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                StatCard(title: "Used", value: Fmt.bytes(report.usedBytes),
                         subtitle: "of \(Fmt.bytes(report.capacityBytes))", color: .primary)
                StatCard(title: "Free", value: Fmt.bytes(report.freeBytes),
                         subtitle: "available now", color: .blue)
                if report.purgeableBytes > 0 {
                    StatCard(title: "Purgeable", value: Fmt.bytes(report.purgeableBytes),
                             subtitle: "OS can reclaim", color: .secondary)
                }
            }
            CapacityBar(report: report)
            if report.fullDiskAccess != .granted {
                note("Full Disk Access is off — Messages, Mail, and protected app data can't be "
                   + "itemized yet, so they're counted under “System & Other.” Grant access for "
                   + "an accurate breakdown.", icon: "lock.shield")
            } else if report.overMeasured {
                note("Some space is shared via file clones, so categories may overlap — "
                   + "the disk total is still exact.", icon: "info.circle")
            } else if report.snapshots.mayPinDeletedBlocks {
                note("\(report.snapshots.count) APFS snapshot(s) present — some used space is "
                   + "pinned by backups and clears within ~24h.", icon: "clock.arrow.circlepath")
            }
        }
    }

    @ViewBuilder private func row(_ c: StorageCategory, report: MacStorageReport) -> some View {
        let files = report.filesByCategory[c.key] ?? []
        if files.isEmpty {
            rowContent(c, report: report, browsable: false)
        } else {
            Button {
                drill = MyMacDrill(category: c, files: files)
            } label: {
                rowContent(c, report: report, browsable: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func rowContent(_ c: StorageCategory, report: MacStorageReport, browsable: Bool) -> some View {
        let pct = report.usedBytes > 0 ? Double(c.bytes) / Double(report.usedBytes) * 100 : 0
        return HStack(spacing: 12) {
            Image(systemName: c.symbol)
                .foregroundStyle(color(for: c.key))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(c.name).fontWeight(.medium)
                    if !c.itemized {
                        Text("not itemized")
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Text(Fmt.bytes(c.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(c.detail).font(.caption).foregroundStyle(.secondary)
            }
            Text(String(format: "%.0f%%", pct))
                .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption).foregroundStyle(.tertiary).opacity(browsable ? 1 : 0)
        }
        .padding(.vertical, 3)
    }

    private var refreshingChip: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Refreshing…").font(.callout)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8, y: 2).padding(.top, 10)
    }

    private func footnote(_ report: MacStorageReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Totals reconcile to your disk's actual used space — the itemized "
               + "categories plus “System & Other” always add up to \(Fmt.bytes(report.usedBytes)).")
            Text("Scanned \(report.totalFileCount.formatted()) files in "
               + "\(String(format: "%.1f", report.elapsedSeconds))s. Viewing only — "
               + "use the Scan tab to reclaim space safely.")
        }
        .font(.caption).foregroundStyle(.secondary).textCase(nil)
    }

    private func note(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for key: String) -> Color { categoryColor(key) }
}

/// A stable color per storage category, shared by the bar and the list so
/// they always agree.
func categoryColor(_ key: String) -> Color {
    switch key {
    case "applications": .blue
    case "media":        .pink
    case "music":        .red
    case "documents":    .teal
    case "downloads":    .cyan
    case "developer":    .orange
    case "mail":         .indigo
    case "messages":     .green
    case "appdata":      .mint
    case "trash":        .brown
    case "userother":    .yellow
    case "systemdata":   .gray
    case "otherusers":   .indigo
    case "protected":    .orange
    case "macos":        .gray
    case "preboot":      .gray
    case "vmswap":       .gray
    case "snapshots":    .secondary
    case "system":       .secondary
    default:             .secondary
    }
}

/// A horizontal stacked bar: each category's share of the whole disk, with the
/// free space as a light track on the right.
private struct CapacityBar: View {
    let report: MacStorageReport

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cap = max(1, Double(report.capacityBytes))
            HStack(spacing: 0) {
                ForEach(report.categories) { c in
                    Rectangle()
                        .fill(categoryColor(c.key))
                        .frame(width: max(0, w * Double(c.bytes) / cap))
                }
                Rectangle().fill(Color.secondary.opacity(0.15)) // free space
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: .infinity)
    }
}
