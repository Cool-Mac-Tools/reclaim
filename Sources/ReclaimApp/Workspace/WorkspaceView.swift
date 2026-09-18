import SwiftUI
import ReclaimCore

/// A second view of Activity's exact snapshot, with no separate connections,
/// category filters, sampling timer or competing resource totals.
struct WorkspaceView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var prominent: [WorkspaceObject] {
        workspace.objects.filter { $0.kind != .storage }.sorted {
            if $0.cpu != $1.cpu { return $0.cpu > $1.cpu }
            return $0.memory > $1.memory
        }
    }
    private var selected: WorkspaceObject? {
        workspace.objects.first { $0.id == workspace.selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                WorkspaceScene(objects: workspace.objects, selectedID: workspace.selectedID, focus: nil,
                    resetToken: workspace.resetCamera, reduceMotion: reduceMotion,
                    select: { workspace.selectedID = $0 })
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drag to orbit · Scroll to zoom · Click an app to inspect")
                    Text("Largest 12 per group shown · Every process is in Activity’s list")
                        .foregroundStyle(.white.opacity(0.6))
                }.font(.caption2).foregroundStyle(.white)
                    .padding(10).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    .padding(12).allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Your Mac, live").font(.headline)
                    Spacer()
                    Button { workspace.resetCamera += 1 } label: { Image(systemName: "viewfinder") }
                        .buttonStyle(.borderless).help("Reset view")
                }
                if let object = selected {
                    Text(object.title).font(.title3.weight(.semibold))
                    Text(object.detail).font(.callout).foregroundStyle(.secondary)
                    if let group = workspace.groups.first(where: { $0.id == object.id }) {
                        Text("Includes \(group.processes.count) process(es) and helpers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if object.pid != nil {
                        Button("Switch to app") { workspace.open(object) }
                    } else if object.kind == .storage {
                        Button("Review storage") { app.section = .myMac }
                    }
                    Button("Show all activity") { app.activityDiagram = false }
                    Divider()
                } else {
                    Text("Applications and background work from the same live sample as the list. Select an object for details.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Most active").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(prominent.prefix(12)) { object in
                            Button { workspace.selectedID = object.id } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(object.title).font(.callout).lineLimit(1)
                                    Text("\(String(format: "%.1f", object.cpu))% CPU · \(Fmt.bytes(object.memory))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if let date = workspace.health?.sampledAt {
                    Text("Updated \(date.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(16).frame(width: 240)
        }
    }
}
