import SwiftUI
import AppKit
import ReclaimCore

/// The branded, screenshot-ready card a user shares after a cleanup — the
/// "GB saved" proof that drives the developer viral loop (plan §12/§14).
/// Fixed size so it renders crisply to an image.
struct ShareCard: View {
    let freed: Int64

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.22, blue: 0.18),
                         Color(red: 0.02, green: 0.09, blue: 0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "internaldrive.fill")
                        .foregroundStyle(Color(red: 0.36, green: 0.9, blue: 0.72))
                    Text("RECLAIM")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .tracking(3).foregroundStyle(.white.opacity(0.92))
                }
                Spacer()
                Text(Fmt.bytes(freed))
                    .font(.system(size: 78, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("reclaimed on my Mac")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.74))
                Spacer()
                Text("github.com/Claytonwendel/reclaim · free")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(38)
        }
        .frame(width: 640, height: 360)
    }
}

/// Celebratory sheet shown right after the user empties quarantine.
struct CelebrationView: View {
    @EnvironmentObject var model: AppModel
    let freed: Int64
    let lifetime: Int64

    @State private var cardImage: NSImage?
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shareText: String {
        "I just reclaimed \(Fmt.bytes(freed)) on my Mac with Reclaim — a free, explainable storage tool. github.com/Claytonwendel/reclaim"
    }

    var body: some View {
        VStack(spacing: 20) {
            Group {
                if let icon = CelebrationIcon.image {
                    Image(nsImage: icon).resizable().interpolation(.high)
                        .frame(width: 76, height: 76)
                } else {
                    Text("🎉").font(.system(size: 54))
                }
            }
            .scaleEffect(appeared || reduceMotion ? 1 : 0.6)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6), value: appeared)

            VStack(spacing: 6) {
                Text("Woohoo! You freed \(Fmt.bytes(freed)).")
                    .font(.title.bold()).multilineTextAlignment(.center)
                Text("That space is back on your Mac. All-time reclaimed: \(Fmt.bytes(lifetime)).")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            // Preview of the shareable card.
            Group {
                if let cardImage {
                    Image(nsImage: cardImage).resizable().scaledToFit()
                } else {
                    ShareCard(freed: freed) // fallback live view
                        .scaleEffect(0.5).frame(width: 320, height: 180)
                }
            }
            .frame(maxWidth: 360)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)

            HStack(spacing: 10) {
                Button {
                    ShareSheet.present(image: cardImage, text: shareText)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up").frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)

                Button("Done") { model.celebration = nil }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .padding(32)
        .frame(width: 440)
        .task {
            // Render the card to an image for a crisp preview + sharing.
            let renderer = ImageRenderer(content: ShareCard(freed: freed))
            renderer.scale = 2
            cardImage = renderer.nsImage
            appeared = true
        }
    }
}

/// Presents the macOS share sheet anchored to the key window.
enum ShareSheet {
    @MainActor
    static func present(image: NSImage?, text: String) {
        var items: [Any] = []
        if let image { items.append(image) }
        items.append(text)
        let picker = NSSharingServicePicker(items: items)
        guard let view = NSApp.keyWindow?.contentView else { return }
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }
}
