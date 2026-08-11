import SwiftUI
import ReclaimCore

/// A squarified treemap of a category's files — each file is a rectangle sized
/// to its share of the shown space, so the big items pop out visually (the
/// DaisyDisk-style "where did my space go" read). Tap to select a file, double-
/// tap to Quick Look. Read-only; selection feeds the same reversible cleanup.
struct TreemapView: View {
    let files: [ClusterFile]
    let tint: Color
    let selected: Set<String>
    let isSelectable: (ClusterFile) -> Bool
    let onToggle: (ClusterFile) -> Void
    let onQuickLook: (ClusterFile) -> Void

    /// Cap the tile count so the map stays legible; the largest files are what
    /// matter for reclaiming space.
    private var shown: [ClusterFile] { Array(files.prefix(80)) }

    var body: some View {
        GeometryReader { geo in
            let tiles = Treemap.layout(shown, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    tileView(tile)
                }
            }
        }
        .padding(6)
    }

    @ViewBuilder private func tileView(_ tile: Treemap.Tile) -> some View {
        let f = tile.file
        let isSel = selected.contains(f.path)
        let canSelect = isSelectable(f)
        let r = tile.rect
        RoundedRectangle(cornerRadius: 4)
            .fill(tint.opacity(isSel ? 0.95 : (canSelect ? 0.45 : 0.18)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.background, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if r.width > 58 && r.height > 26 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text((f.path as NSString).lastPathComponent)
                            .font(.caption2).fontWeight(.medium).lineLimit(1)
                        Text(Fmt.bytes(f.bytes)).font(.system(size: 9)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                    .foregroundStyle(isSel ? Color.white : Color.primary)
                    .frame(maxWidth: r.width - 4, alignment: .leading)
                }
            }
            .frame(width: max(0, r.width - 2), height: max(0, r.height - 2))
            .position(x: r.midX, y: r.midY)
            .help("\((f.path as NSString).lastPathComponent) · \(Fmt.bytes(f.bytes))")
            .onTapGesture(count: 2) { onQuickLook(f) }
            .onTapGesture(count: 1) { if canSelect { onToggle(f) } }
    }
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk). Pure geometry so it's
/// unit-testable and independent of SwiftUI.
enum Treemap {
    struct Tile: Identifiable {
        let file: ClusterFile
        let rect: CGRect
        var id: String { file.path }
    }

    static func layout(_ files: [ClusterFile], in frame: CGRect) -> [Tile] {
        let values = files.filter { $0.bytes > 0 }
        let total = values.reduce(0.0) { $0 + Double($1.bytes) }
        guard total > 0, frame.width > 0, frame.height > 0 else { return [] }

        let area = Double(frame.width) * Double(frame.height)
        let scaled = values.map { (file: $0, area: Double($0.bytes) / total * area) }

        var tiles: [Tile] = []
        var rect = frame
        var row: [(file: ClusterFile, area: Double)] = []

        func shortest(_ r: CGRect) -> Double { Double(min(r.width, r.height)) }
        func worst(_ row: [(file: ClusterFile, area: Double)], _ side: Double) -> Double {
            guard !row.isEmpty, side > 0 else { return .greatestFiniteMagnitude }
            let sum = row.reduce(0) { $0 + $1.area }
            guard sum > 0 else { return .greatestFiniteMagnitude }
            let maxA = row.map(\.area).max()!, minA = row.map(\.area).min()!
            let s2 = side * side
            return max(s2 * maxA / (sum * sum), sum * sum / (s2 * minA))
        }
        func placeRow(_ row: [(file: ClusterFile, area: Double)], _ r: CGRect) -> CGRect {
            let sum = row.reduce(0) { $0 + $1.area }
            guard sum > 0 else { return r }
            if r.width >= r.height {
                let w = CGFloat(sum / Double(r.height))
                var y = r.minY
                for it in row {
                    let h = CGFloat(it.area / sum) * r.height
                    tiles.append(Tile(file: it.file, rect: CGRect(x: r.minX, y: y, width: w, height: h)))
                    y += h
                }
                return CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height)
            } else {
                let h = CGFloat(sum / Double(r.width))
                var x = r.minX
                for it in row {
                    let w = CGFloat(it.area / sum) * r.width
                    tiles.append(Tile(file: it.file, rect: CGRect(x: x, y: r.minY, width: w, height: h)))
                    x += w
                }
                return CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h)
            }
        }

        var i = 0
        while i < scaled.count {
            let item = scaled[i]
            let side = shortest(rect)
            if row.isEmpty || worst(row, side) >= worst(row + [item], side) {
                row.append(item)
                i += 1
            } else {
                rect = placeRow(row, rect)
                row = []
            }
        }
        if !row.isEmpty { _ = placeRow(row, rect) }
        return tiles
    }
}
