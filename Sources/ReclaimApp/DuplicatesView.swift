import SwiftUI
import ReclaimCore

/// The duplicate finder: byte-identical files grouped together. By default we
/// keep the newest copy of each group and pre-select the rest for the reversible
/// quarantine — so "reclaim all duplicates" is one click, but every choice is
/// visible and editable.
struct DuplicatesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let groups: [DuplicateGroup]

    @State private var selected: Set<String>

    init(groups: [DuplicateGroup]) {
        self.groups = groups
        _selected = State(initialValue: Set(groups.flatMap { $0.extras.map(\.path) }))
    }

    private var selectedBytes: Int64 {
        groups.flatMap(\.files).filter { selected.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }
    private var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(groups) { group in
                    Section {
                        if let keeper = group.keeper { keeperRow(keeper) }
                        ForEach(group.extras) { extraRow($0) }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 600)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.doc.fill").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate files").font(.headline)
                Text("\(groups.count) group\(groups.count == 1 ? "" : "s") · up to \(Fmt.bytes(totalReclaimable)) reclaimable")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding(14)
    }

    private func groupHeader(_ g: DuplicateGroup) -> some View {
        HStack {
            Text(g.keeper.map { ($0.path as NSString).lastPathComponent } ?? "Identical files")
                .font(.subheadline.weight(.semibold)).textCase(nil).lineLimit(1)
            Spacer()
            Text("\(g.count) copies · \(Fmt.bytes(g.bytes)) each · save \(Fmt.bytes(g.reclaimableBytes))")
                .font(.caption).foregroundStyle(.secondary).textCase(nil)
        }
        .padding(.vertical, 2)
    }

    private func keeperRow(_ file: ClusterFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).frame(width: 16)
            ThumbView(path: file.path)
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).lastPathComponent).fontWeight(.medium).lineLimit(1)
                Text("Keep — newest copy · \(pathTail(file.path))")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            revealButton(file.path)
        }
        .padding(.vertical, 2)
    }

    private func extraRow(_ file: ClusterFile) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { selected.contains(file.path) },
                set: { on in if on { selected.insert(file.path) } else { selected.remove(file.path) } }))
                .labelsHidden().toggleStyle(.checkbox)
            ThumbView(path: file.path)
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).lastPathComponent).fontWeight(.medium).lineLimit(1)
                Text(pathTail(file.path)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            revealButton(file.path)
        }
        .padding(.vertical, 2)
    }

    private func revealButton(_ path: String) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless).help("Reveal in Finder")
    }

    /// The parent folder, shortened with ~, so identical filenames are still
    /// distinguishable by location.
    private func pathTail(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }

    private var footer: some View {
        HStack {
            Text("\(selected.count) copies selected · \(Fmt.bytes(selectedBytes))")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button {
                let targets = groups.flatMap(\.files)
                    .filter { selected.contains($0.path) }
                    .map { CleanupTarget(path: $0.path, riskTier: .blue, source: "duplicate") }
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
