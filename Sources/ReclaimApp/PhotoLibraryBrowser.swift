import SwiftUI
import ReclaimCore

/// An async thumbnail tile backed by PhotoKit (not a file path), since library
/// assets have no stable on-disk path. Shows a placeholder until the preview
/// arrives, and a play badge for videos.
struct PhotoThumb: View {
    let id: String
    let isVideo: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: isVideo ? "video" : "photo")
                    .foregroundStyle(.tertiary)
            }
            if isVideo {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(3)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: id) { image = await PhotoLibrary.thumbnail(for: id) }
    }
}

/// Browse the Photos library at the asset level — individual photos and videos
/// with real sizes, filter by size/age/type, bulk-select, and move to Photos'
/// Recently Deleted (recoverable 30 days). Mirrors `CategoryBrowser`'s
/// filter→select-all→act pattern, adapted to PhotoKit assets.
struct PhotoLibraryBrowser: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<String> = []
    @State private var sort: Sort = .largest
    @State private var sizeFilter: SizeFilter = .any
    @State private var ageFilter: AgeFilter = .any
    @State private var kind: Kind = .all
    @State private var confirmDelete = false

    enum Sort: String, CaseIterable, Identifiable {
        case largest = "Largest", oldest = "Oldest", newest = "Newest"
        var id: String { rawValue }
    }
    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", photos = "Photos", videos = "Videos"
        var id: String { rawValue }
    }

    private var assets: [PhotoLibrary.Asset] { model.photoAssets }

    private var filtered: [PhotoLibrary.Asset] {
        let now = Date()
        let matched = assets.filter { a in
            a.bytes >= sizeFilter.minBytes
            && ageFilter.matches(a.creationDate, now: now)
            && (kind == .all || (kind == .videos) == a.isVideo)
        }
        switch sort {
        case .largest: return matched.sorted { $0.bytes > $1.bytes }
        case .oldest:  return matched.sorted { ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture) }
        case .newest:  return matched.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        }
    }
    private var filteredBytes: Int64 { filtered.reduce(0) { $0 + $1.bytes } }
    private var selectedAssets: [PhotoLibrary.Asset] { assets.filter { selected.contains($0.id) } }
    private var selectedBytes: Int64 { selectedAssets.reduce(0) { $0 + $1.bytes } }
    private var selectedFavorites: Int { selectedAssets.filter(\.isFavorite).count }
    private var allFilteredSelected: Bool {
        !filtered.isEmpty && filtered.allSatisfy { selected.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.photosLoading && !model.photoAuthDenied && !assets.isEmpty {
                filterBar
                Divider()
            }
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 600)
        .onAppear { model.loadPhotos() }
        .confirmationDialog(
            "Move \(selected.count) item\(selected.count == 1 ? "" : "s") — \(Fmt.bytes(selectedBytes)) — to Recently Deleted?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Move to Recently Deleted", role: .destructive) {
                model.deletePhotos(ids: selected); selected = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selectedFavorites > 0
                 ? "\(selectedFavorites) of these are Favorites. You can recover everything in Photos for 30 days. macOS will ask you to confirm."
                 : "You can recover them in Photos for 30 days. macOS will ask you to confirm.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.stack").font(.title3).foregroundStyle(.pink)
            VStack(alignment: .leading, spacing: 2) {
                Text("Photos Library").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !assets.isEmpty {
                Picker("", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 210)
            }
            Button("Open Photos") { NSWorkspace.shared.open(URL(string: "photos://")!) }
                .help("Open the Photos app")
            Button("Done") { dismiss() }
        }
        .padding(14)
    }

    private var subtitle: String {
        guard let scan = model.photoScan else { return "Reading your library…" }
        var s = "\(scan.totalCount.formatted()) items · \(Fmt.bytes(scan.totalBytes)) on this Mac"
        if scan.assets.count < scan.localCount {
            s += " · showing largest \(scan.assets.count.formatted())"
        }
        return s
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(width: 190).labelsHidden()

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

            if sizeFilter != .any || ageFilter != .any || kind != .all {
                Button { sizeFilter = .any; ageFilter = .any; kind = .all } label: {
                    Text("Clear").font(.caption)
                }.buttonStyle(.link)
            }

            Spacer()

            Text("\(filtered.count) match · \(Fmt.bytes(filteredBytes))")
                .font(.caption).foregroundStyle(.secondary)
            Button(allFilteredSelected ? "Deselect all" : "Select all matching") {
                if allFilteredSelected { filtered.forEach { selected.remove($0.id) } }
                else { filtered.forEach { selected.insert($0.id) } }
            }
            .disabled(filtered.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.quaternary.opacity(0.25))
    }

    // MARK: - Content states

    @ViewBuilder private var content: some View {
        if model.photosLoading {
            loadingState
        } else if model.photoAuthDenied {
            deniedState
        } else if assets.isEmpty {
            ContentUnavailableView("No photos or videos found",
                systemImage: "photo.on.rectangle",
                description: Text("Your Photos library looks empty, or nothing is stored on this Mac."))
                .frame(maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView("Nothing matches these filters",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Loosen the size, age, or type filter."))
                .frame(maxHeight: .infinity)
        } else {
            List(filtered) { asset in row(asset) }.listStyle(.inset)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            let p = model.photoProgress
            Text(p.total > 0 ? "Reading your library… \(p.done.formatted()) of \(p.total.formatted())"
                             : "Opening your Photos library…")
                .font(.callout).foregroundStyle(.secondary)
            Text("Measuring each photo and video's real size.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedState: some View {
        ContentUnavailableView {
            Label("Photos access needed", systemImage: "lock")
        } description: {
            Text("Reclaim needs permission to read your Photos library so it can show individual photos and videos. Your photos never leave this Mac.")
        } actions: {
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
            }.buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Row

    @ViewBuilder private func row(_ a: PhotoLibrary.Asset) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { selected.contains(a.id) },
                set: { on in if on { selected.insert(a.id) } else { selected.remove(a.id) } }))
                .labelsHidden().toggleStyle(.checkbox)
            PhotoThumb(id: a.id, isVideo: a.isVideo)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(a.filename).fontWeight(.medium).lineLimit(1)
                    if a.isFavorite {
                        Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink)
                    }
                }
                Text(subline(a)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if a.isLocal {
                Text(Fmt.bytes(a.bytes)).monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text("iCloud").font(.caption).foregroundStyle(.tertiary)
                    .help("Stored in iCloud — no space used on this Mac")
            }
        }
        .padding(.vertical, 2)
    }

    private func subline(_ a: PhotoLibrary.Asset) -> String {
        var parts: [String] = [a.isVideo ? "Video" : "Photo"]
        if a.pixelWidth > 0 && a.pixelHeight > 0 { parts.append("\(a.pixelWidth)×\(a.pixelHeight)") }
        if let d = a.creationDate {
            let days = Int(Date().timeIntervalSince(d) / 86400)
            parts.append("\(d.formatted(date: .abbreviated, time: .omitted)) · \(days) days ago")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(selected.count) selected · \(Fmt.bytes(selectedBytes))")
                    .font(.callout).foregroundStyle(.secondary)
                if !assets.isEmpty {
                    Text("Removed items go to Photos → Recently Deleted (recoverable 30 days).")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                confirmDelete = true
            } label: {
                Text("Move \(Fmt.bytes(selectedBytes)) to Recently Deleted").frame(minWidth: 230)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty || model.busy != nil)
        }
        .padding(14)
    }
}
