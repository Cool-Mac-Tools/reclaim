import SwiftUI
import ReclaimCore

/// A recursive folder tree: expand a directory to reveal its contents, select
/// parts to reclaim, ask AI about any of them, and drill deeper. Selection
/// flows into a shared `Set<String>` of paths; expanding registers each child's
/// target (via `register`) so the container's clean action can act on them.
struct ExpandableNodeRows: View {
    let nodes: [FileNode]
    let depth: Int
    let tier: RiskTier
    let source: String
    @Binding var selected: Set<String>
    let register: ([FileNode]) -> Void
    @Binding var aiRequest: AppModel.AIRequest?

    var body: some View {
        ForEach(nodes) { node in
            NodeRow(node: node, depth: depth, tier: tier, source: source,
                    selected: $selected, register: register, aiRequest: $aiRequest)
        }
    }
}

private struct NodeRow: View {
    @EnvironmentObject var ai: AISettings
    let node: FileNode
    let depth: Int
    let tier: RiskTier
    let source: String
    @Binding var selected: Set<String>
    let register: ([FileNode]) -> Void
    @Binding var aiRequest: AppModel.AIRequest?

    @State private var expanded = false
    @State private var children: [FileNode]?
    @State private var loading = false

    private var removable: Bool {
        CleanupExecutor.isRemovable(node.path) && !MacStorageMap.isAtomicBundle(node.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer().frame(width: CGFloat(depth) * 16)
                if node.isDirectory {
                    Button { toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).frame(width: 12)
                    }.buttonStyle(.borderless)
                } else {
                    Spacer().frame(width: 12)
                }
                if removable {
                    Toggle("", isOn: Binding(
                        get: { selected.contains(node.path) },
                        set: { on in if on { selected.insert(node.path) } else { selected.remove(node.path) } }))
                        .labelsHidden().toggleStyle(.checkbox)
                } else {
                    Image(systemName: "lock").font(.caption2).foregroundStyle(.tertiary).frame(width: 14)
                }
                Image(nsImage: NSWorkspace.shared.icon(forFile: node.path))
                    .resizable().frame(width: 16, height: 16)
                Text(node.name).font(.callout).lineLimit(1)
                Spacer()
                Text(Fmt.bytes(node.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if ai.isReady {
                    AISparkButton { aiRequest = AppModel.request(forNode: node, category: source) }
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
                } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Reveal in Finder")
            }
            .padding(.vertical, 2)

            if expanded {
                if loading {
                    HStack(spacing: 8) {
                        Spacer().frame(width: CGFloat(depth + 1) * 16 + 12)
                        ProgressView().controlSize(.small)
                        Text("Reading folder…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(.vertical, 2)
                } else if let children {
                    if children.isEmpty {
                        HStack { Spacer().frame(width: CGFloat(depth + 1) * 16 + 12)
                            Text("Empty").font(.caption).foregroundStyle(.tertiary); Spacer() }
                    } else {
                        ExpandableNodeRows(nodes: children, depth: depth + 1, tier: tier, source: source,
                                           selected: $selected, register: register, aiRequest: $aiRequest)
                    }
                }
            }
        }
    }

    private func toggle() {
        expanded.toggle()
        guard expanded, children == nil else { return }
        loading = true
        Task {
            let kids = await Task.detached(priority: .userInitiated) {
                DirLister.children(of: node.path)
            }.value
            register(kids)
            self.children = kids
            self.loading = false
        }
    }
}
