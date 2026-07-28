import SwiftUI
import ReclaimCore

/// What a drilled-into category carries: its files plus whether the user may
/// act on them. Personal/user categories are actionable (quarantine, always
/// reversible); system categories are view-only.
struct MyMacDrill: Identifiable {
    let id: String            // category key
    let name: String
    let symbol: String
    let files: [ClusterFile]
    let categoryBytes: Int64  // total for the whole category (all files)
    let actionable: Bool
    let tier: RiskTier

    /// Which categories a user may bulk-send to quarantine from My Mac. System,
    /// other-users, and applications are view-only — deleting individual files
    /// there is unsafe even reversibly, and apps belong to a future uninstall flow.
    static let actionableKeys: Set<String> = [
        "media", "music", "documents", "downloads",
        "userother", "trash", "developer", "appdata",
    ]

    static func tier(for key: String) -> RiskTier {
        switch key {
        case "developer", "appdata", "trash": .blue   // regenerable / re-downloadable
        default:                              .orange  // personal content
        }
    }

    init(category: StorageCategory, files: [ClusterFile]) {
        self.id = category.key
        self.name = category.name
        self.symbol = category.symbol
        self.files = files
        self.categoryBytes = category.bytes
        self.actionable = Self.actionableKeys.contains(category.key)
        self.tier = Self.tier(for: category.key)
    }
}

/// Browse one category's largest files, filter by size/age, bulk-select, and
/// send to the reversible quarantine. Same filter→select-all→act pattern as the
/// media browser, generalized to any category.
struct CategoryBrowser: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ai: AISettings
    @Environment(\.dismiss) private var dismiss
    let drill: MyMacDrill

    @State private var selected: Set<String> = []
    @State private var sort: Sort = .largest
    @State private var sizeFilter: SizeFilter = .any
    @State private var ageFilter: AgeFilter = .any
    @State private var aiRequest: AppModel.AIRequest?   // this sheet presents its own AI popup

    enum Sort: String, CaseIterable, Identifiable {
        case largest = "Largest", oldest = "Oldest", newest = "Newest"
        var id: String { rawValue }
    }

    private var filtered: [ClusterFile] {
        let now = Date()
        let matched = drill.files.filter {
            $0.bytes >= sizeFilter.minBytes && ageFilter.matches($0.modified, now: now)
        }
        switch sort {
        case .largest: return matched.sorted { $0.bytes > $1.bytes }
        case .oldest:  return matched.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
        case .newest:  return matched.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
    }
    private var filteredBytes: Int64 { filtered.reduce(0) { $0 + $1.bytes } }
    private var selectedBytes: Int64 {
        drill.files.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }
    private func isBundle(_ f: ClusterFile) -> Bool { MacStorageMap.isAtomicBundle(f.path) }
    /// Removable = not a library/app bundle and owned by this user. Gated
    /// per-file (any category), so everything a user can safely delete is
    /// deletable; system/other-owned files stay locked with a clear reason.
    private func removable(_ f: ClusterFile) -> Bool {
        !isBundle(f) && CleanupExecutor.isRemovable(f.path)
    }
    private var selectableFiltered: [ClusterFile] { filtered.filter(removable) }
    private var allFilteredSelected: Bool {
        !selectableFiltered.isEmpty && selectableFiltered.allSatisfy { selected.contains($0.path) }
    }
    private var shownBytes: Int64 { drill.files.reduce(0) { $0 + $1.bytes } }
    /// The slice of the category not listed here: small files (<1 MB) plus
    /// protected bundle contents (e.g. your Photos library, app internals).
    private var notShownBytes: Int64 { max(0, drill.categoryBytes - shownBytes) }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            if notShownBytes > 50 * 1024 * 1024 {
                Label("\(Fmt.bytes(notShownBytes)) more isn't listed here — files under 1 MB and "
                    + "protected bundle contents (like your Photos library or app internals), which "
                    + "aren't safe to remove individually.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.quaternary.opacity(0.15))
            }
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView("Nothing matches these filters",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Loosen the size or age filter."))
                    .frame(maxHeight: .infinity)
            } else {
                List(filtered) { file in
                    row(file)
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .frame(minWidth: 600, minHeight: 580)
        .sheet(item: $aiRequest) { req in
            AIExplainSheet(request: req).environmentObject(ai)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: drill.symbol).font(.title3).foregroundStyle(categoryColor(drill.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(drill.name).font(.headline)
                Text("\(drill.files.count) files · \(Fmt.bytes(shownBytes)) shown of \(Fmt.bytes(drill.categoryBytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(width: 210)
            Button("Done") { dismiss() }
        }
        .padding(14)
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(SizeFilter.allCases) { f in Button(f.rawValue) { sizeFilter = f } }
            } label: {
                Label(sizeFilter == .any ? "Size" : sizeFilter.rawValue, systemImage: "arrow.up.arrow.down.circle")
            }.menuStyle(.borderlessButton).fixedSize()

            Menu {
                ForEach(AgeFilter.allCases) { f in Button(f.rawValue) { ageFilter = f } }
            } label: {
                Label(ageFilter == .any ? "Age" : ageFilter.rawValue, systemImage: "calendar")
            }.menuStyle(.borderlessButton).fixedSize()

            if sizeFilter != .any || ageFilter != .any {
                Button { sizeFilter = .any; ageFilter = .any } label: { Text("Clear").font(.caption) }
                    .buttonStyle(.link)
            }

            Spacer()

            Text("\(filtered.count) match · \(Fmt.bytes(filteredBytes))")
                .font(.caption).foregroundStyle(.secondary)
            Button(allFilteredSelected ? "Deselect all" : "Select all matching") {
                if allFilteredSelected { selectableFiltered.forEach { selected.remove($0.path) } }
                else { selectableFiltered.forEach { selected.insert($0.path) } }
            }
            .disabled(selectableFiltered.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.quaternary.opacity(0.25))
    }

    @ViewBuilder private func row(_ file: ClusterFile) -> some View {
        let bundle = isBundle(file)
        HStack(spacing: 12) {
            if removable(file) {
                Toggle("", isOn: Binding(
                    get: { selected.contains(file.path) },
                    set: { on in if on { selected.insert(file.path) } else { selected.remove(file.path) } }))
                    .labelsHidden().toggleStyle(.checkbox)
            } else if bundle {
                Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 16)
                    .help("A bundle (library or app) — open to manage; never removed piece by piece")
            } else {
                Image(systemName: "lock").foregroundStyle(.tertiary).frame(width: 16)
                    .help("Owned by the system or another account — needs admin rights to remove")
            }
            ThumbView(path: file.path)
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).lastPathComponent).fontWeight(.medium).lineLimit(1)
                Text(bundle ? "Library/app bundle — open to manage; not removed piece by piece"
                            : dateLine(file))
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Text(Fmt.bytes(file.bytes)).monospacedDigit().foregroundStyle(.secondary)
            if ai.isReady { AISparkButton { aiRequest = AppModel.request(forFile: file, category: drill.name) } }
            if bundle {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
                } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless).help("Open")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Reveal in Finder")
        }
        .padding(.vertical, 2)
    }

    private func dateLine(_ file: ClusterFile) -> String {
        guard let d = file.modified else { return "date unknown" }
        let days = Int(Date().timeIntervalSince(d) / 86400)
        return "\(d.formatted(date: .abbreviated, time: .omitted)) · \(days) days ago"
    }

    private var footer: some View {
        HStack {
            Text("\(selected.count) selected · \(Fmt.bytes(selectedBytes))")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button {
                let targets = drill.files
                    .filter { selected.contains($0.path) && removable($0) }
                    .map { CleanupTarget(path: $0.path, riskTier: drill.tier, source: "my-mac") }
                model.reclaim(targets)
                dismiss()
            } label: {
                Text("Send \(Fmt.bytes(selectedBytes)) to Quarantine").frame(minWidth: 190)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty || model.busy != nil)
        }
        .padding(14)
    }
}
