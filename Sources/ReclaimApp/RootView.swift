import SwiftUI
import ReclaimCore

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // The FDA banner spans the full window top, ABOVE the split view — so it
        // never interferes with each detail view's own navigationTitle/toolbar.
        VStack(spacing: 0) {
            if model.needsFullDiskAccess { FDABanner() }
            NavigationSplitView {
                List(AppModel.Section.allCases, selection: $model.section) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .tag(section)
                }
                .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 260)
                .safeAreaInset(edge: .bottom) { sidebarFooter }
            } detail: {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { busyBanner }
            }
        }
        .sheet(item: $model.celebration) { c in
            CelebrationView(freed: c.freed, lifetime: c.lifetime)
                .environmentObject(model)
        }
        .alert("Reclaim", isPresented: Binding(
            get: { model.actionAlert != nil },
            set: { if !$0 { model.actionAlert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionAlert ?? "")
        }
        .sheet(item: $model.aiRequest) { req in
            AIExplainSheet(request: req).environmentObject(AISettings.shared)
        }
        .task {
            model.loadQuarantine()
            model.refreshFDA()
        }
        // Re-check when the user comes back from System Settings.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFDA()
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .scan:       ScanView()
        case .myMac:      MyMacView()
        case .quarantine: QuarantineView()
        case .history:    HistoryView()
        case .ai:         AIView()
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.needsFullDiskAccess { sidebarFDAHint }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("Reclaimed all-time")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(Fmt.bytes(model.lifetimeReclaimed))
                    .font(.callout.weight(.semibold)).foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    /// A persistent sidebar nudge — always visible until access is granted.
    private var sidebarFDAHint: some View {
        Button { model.openFDASettings() } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Disk Access off")
                        .font(.caption.weight(.semibold))
                    Text("Turn on to see & clean everything")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var busyBanner: some View {
        if let busy = model.busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(busy).font(.callout)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8, y: 2)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Shared components

/// A big number card for the dashboard headers.
struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String
    var color: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Looks up the real icon of a running app by its display name, so blocked
/// rows can show "[Cursor icon] Cursor". Cached for the session.
@MainActor
enum RunningAppIcon {
    private static var cache: [String: NSImage] = [:]

    static func icon(for name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        let apps = NSWorkspace.shared.runningApplications
        let match = apps.first { $0.localizedName == name }
            ?? apps.first { ($0.localizedName ?? "").localizedCaseInsensitiveContains(name) }
        if let icon = match?.icon { cache[name] = icon; return icon }
        return nil
    }
}

/// A small "[icon] AppName" chip shown next to items blocked by a running app.
struct AppChip: View {
    let name: String
    var body: some View {
        HStack(spacing: 4) {
            if let icon = RunningAppIcon.icon(for: name) {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }
            Text(name).font(.caption)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .foregroundStyle(.secondary)
    }
}

/// A colored tier dot + label.
struct TierBadge: View {
    let tier: RiskTier
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tier.color).frame(width: 8, height: 8)
            Text(tier.displayName)
        }
    }
}

/// A prominent, non-dismissible banner shown across every tab while Full Disk
/// Access is off — because it gates both accurate storage *showing* (the My Mac
/// map) and safe *saving* (cleaning protected caches). Clearing it is the
/// single highest-impact thing a new user can do.
struct FDABanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 22)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Turn on Full Disk Access for the full picture")
                    .font(.callout.weight(.semibold))
                Text("Without it, macOS hides Messages, Mail, and protected app data — "
                   + "so your storage looks smaller than it is and some cleanups are off-limits.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button { model.openFDASettings() } label: {
                    Text("Open Settings").frame(minWidth: 108)
                }
                .buttonStyle(.borderedProminent).controlSize(.regular)
                Button("Re-check") { model.refreshFDA() }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.orange.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The empty/prompt state shown before a section has been run.
struct SectionPrompt: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String
    var loading: Bool = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if loading {
                ProgressView().controlSize(.large)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
