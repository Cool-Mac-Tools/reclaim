import SwiftUI
import ReclaimCore

/// The cleanup timeline: proof of value over time. Surfaces the append-only
/// ledger as a lifetime total, a recent-activity chart, and a per-session log —
/// the "prove the outcome" principle, and the hook that earns repeat use.
struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.historyError ?? model.historyWriteError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                    .foregroundStyle(.orange).padding()
                Button("Retry loading history") { model.loadQuarantine() }.padding(.bottom)
            }
            if model.history.isEmpty && model.purgeHistory.isEmpty && model.historyError == nil {
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
        return model.purgeHistory
            .filter { cal.isDate($0.date, equalTo: Date(), toGranularity: .month) }
            .reduce(0) { $0 + $1.verifiedFreedBytes }
    }

    private var content: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        StatCard(title: "Space recovered", value: model.historyError != nil && model.purgeHistory.isEmpty ? "Unavailable" : Fmt.bytes(model.lifetimeReclaimed),
                                 subtitle: "measured free-space increase",
                                 color: .green)
                        StatCard(title: "This month", value: Fmt.bytes(thisMonthBytes),
                                 subtitle: "reclaimed since the 1st", color: .blue)
                        StatCard(title: "In quarantine", value: Fmt.bytes(model.stagedBytes),
                                 subtitle: "staged · reversible", color: .orange)
                    }
                    if recent.count >= 2 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recently moved to quarantine").font(.caption).foregroundStyle(.secondary)
                            HistoryBarChart(entries: recent)
                        }
                    }
                }
                .listRowSeparator(.hidden)
            }

            if model.stagedBytes > 0 {
                Section {
                    Text("\(Fmt.bytes(model.stagedBytes)) is safely staged in quarantine. It still occupies disk space. Review Quarantine and empty it when you're ready to permanently recover that space.")
                    Button("Review Quarantine") { model.section = .quarantine }
                }
            }
            Section("Verified recovery") {
                ForEach(model.purgeHistory.reversed()) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            if let operation = entry.operation { Text(operation).font(.caption).foregroundStyle(.secondary) }
                            Text("\(Fmt.bytes(entry.deletedBytes)) deleted · \(entry.failed.count) failed sessions")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Fmt.bytes(entry.verifiedFreedBytes)).foregroundStyle(.green).monospacedDigit()
                    }
                }
                Text("Recovery totals use measured free-space increases after permanent deletion. Earlier quarantine-only sessions are not counted as verified recovery.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Moved to quarantine") {
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
                Text("\(count) item\(count == 1 ? "" : "s") staged")
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
