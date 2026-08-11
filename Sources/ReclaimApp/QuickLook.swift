import SwiftUI
import Quartz

/// An identifiable URL wrapper so a file can drive a `.sheet(item:)`.
struct PreviewItem: Identifiable {
    let id: String
    let url: URL
    init(path: String) { self.id = path; self.url = URL(fileURLWithPath: path) }
}

/// Inline Quick Look — the same rich preview Finder shows when you press Space,
/// embedded in a sheet. Read-only: previewing never modifies a file.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as NSURL
    }
}

/// A framed Quick Look sheet with the file name, a Reveal-in-Finder action, and
/// a Done button — presented from any browser row.
struct QuickLookSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: PreviewItem

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "eye").foregroundStyle(.secondary)
                Text((item.url.path as NSString).lastPathComponent)
                    .fontWeight(.medium).lineLimit(1)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: { Label("Reveal in Finder", systemImage: "magnifyingglass") }
                    .buttonStyle(.link)
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()
            QuickLookPreview(url: item.url)
                .frame(minWidth: 560, minHeight: 460)
        }
        .frame(minWidth: 600, minHeight: 540)
    }
}
