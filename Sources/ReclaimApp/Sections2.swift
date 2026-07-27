import SwiftUI
import ReclaimCore

struct QuarantineView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmEmpty = false

    var body: some View {
        Group {
            if model.sessions.isEmpty {
                empty
            } else {
                content
            }
        }
        .navigationTitle("Quarantine")
        .onAppear { model.loadQuarantine() }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Quarantine is empty", systemImage: "arrow.uturn.backward.circle")
        } description: {
            if let freed = model.lastFreedBytes, freed > 0 {
                Text("You freed \(Fmt.bytes(freed)). Nice.")
            } else {
                Text("When you clean items they're moved here first — reversible until you empty it.")
            }
        }
    }

    private var content: some View {
        List {
            // The key explainer: staged ≠ freed.
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.bytes(model.stagedBytes))
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("staged for removal · reversible")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            confirmEmpty = true
                        } label: {
                            Text("Empty & Free Space").frame(minWidth: 140)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.busy != nil)
                    }
                    Text("Cleaning **moves** items here — it doesn't free disk space yet. Restore anything you want back, or empty quarantine to permanently delete it and reclaim the space.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let freed = model.lastFreedBytes {
                        Divider()
                        if freed > 0 {
                            Label("Last empty freed \(Fmt.bytes(freed)).", systemImage: "checkmark.circle.fill")
                                .font(.callout).foregroundStyle(.green)
                        } else if model.lastPurgeSnapshotLag {
                            Label("Deleted, but free space hasn't risen yet — APFS snapshots still pin the blocks (clears within ~24h).",
                                  systemImage: "clock.arrow.circlepath")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("In quarantine") {
                ForEach(model.sessions) { s in
                    DisclosureGroup {
                        ForEach(s.entries, id: \.quarantinePath) { e in
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: e.quarantinePath))
                                    .resizable().frame(width: 18, height: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((e.originalPath as NSString).lastPathComponent).font(.callout)
                                    Text(relPath(e.originalPath)).font(.caption2)
                                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(Fmt.bytes(e.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 1)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sessionLabel(s.id)).fontWeight(.medium)
                                Text("\(s.count) item(s)").font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(Fmt.bytes(s.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            Button("Restore") { model.restore(s.id) }.buttonStyle(.bordered)
                            Button("Delete") { model.purge(s.id) }.buttonStyle(.bordered).tint(.red)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.inset)
        .confirmationDialog("Permanently delete everything in quarantine?",
                            isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Empty & Free \(Fmt.bytes(model.stagedBytes))", role: .destructive) { model.emptyAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Restore anything you want to keep first.")
        }
    }

    /// Parent folder of an original path, ~-shortened.
    private func relPath(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }

    /// Turn a yyyyMMdd-HHmmss id into something friendlier.
    private func sessionLabel(_ id: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        guard let d = f.date(from: id) else { return id }
        let out = DateFormatter(); out.dateStyle = .medium; out.timeStyle = .short
        return out.string(from: d)
    }
}
