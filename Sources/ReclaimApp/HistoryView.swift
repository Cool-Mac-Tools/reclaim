import SwiftUI
import ReclaimCore

/// The cleanup timeline: proof of value over time. Surfaces the append-only
/// ledger as a lifetime total, a recent-activity chart, and a per-session log —
/// the "prove the outcome" principle, and the hook that earns repeat use.
struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.history.isEmpty {
                empty
            } else {
                content
            }
        }
        .navigationTitle("History")
        .onAppear { model.loadQuarantine() }   // also refreshes history
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No cleanups yet", systemImage: "chart.bar.xaxis")
        } description: {
            Text("Once you reclaim space, every cleanup is logged here — with a running total of how much you've taken back.")
        }
    }

    // Recent sessions, oldest→newest, for the chart.
    private var recent: [CleanupLedgerEntry] {
        Array(model.history.prefix(16).reversed())
    }
    private var thisMonthBytes: Int64 {
        let cal = Calendar.current
        return model.history
            .filter { cal.isDate($0.startedAt, equalTo: Date(), toGranularity: .month) }
            .reduce(0) { $0 + $1.quarantinedBytes }
    }

    private var content: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        StatCard(title: "Reclaimed all-time", value: Fmt.bytes(model.lifetimeReclaimed),
                                 subtitle: "across \(model.history.count) cleanup\(model.history.count == 1 ? "" : "s")",
                                 color: .green)
                        StatCard(title: "This month", value: Fmt.bytes(thisMonthBytes),
                                 subtitle: "reclaimed since the 1st", color: .blue)
                        StatCard(title: "In quarantine", value: Fmt.bytes(model.stagedBytes),
                                 subtitle: "staged · reversible", color: .orange)
                    }
                    if recent.count >= 2 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recent cleanups").font(.caption).foregroundStyle(.secondary)
                            HistoryBarChart(entries: recent)
                        }
                    }
                }
                .listRowSeparator(.hidden)
            }

            Section("Every cleanup") {
                ForEach(model.history, id: \.sessionID) { entry in
                    sessionRow(entry)
                }
            }
        }
        .listStyle(.inset)
    }

    private func sessionRow(_ entry: CleanupLedgerEntry) -> some View {
        let count = entry.results.filter { $0.status == .quarantined }.count
        return HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.green.opacity(0.85)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .fontWeight(.medium)
                Text("\(count) item\(count == 1 ? "" : "s") reclaimed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Fmt.bytes(entry.quarantinedBytes)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A lightweight bar chart of bytes reclaimed per recent session — no external
/// charting dependency, tuned to feel like a dashboard, not a toy.
private struct HistoryBarChart: View {
    let entries: [CleanupLedgerEntry]   // chronological, oldest→newest

    var body: some View {
        let maxBytes = max(1, entries.map(\.quarantinedBytes).max() ?? 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(entries, id: \.sessionID) { e in
                    let frac = Double(e.quarantinedBytes) / Double(maxBytes)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.green.gradient)
                        .frame(height: max(3, geo.size.height * frac))
                        .frame(maxWidth: .infinity)
                        .help("\(Fmt.bytes(e.quarantinedBytes)) · \(e.startedAt.formatted(date: .abbreviated, time: .omitted))")
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 84)
    }
}
