import SwiftUI

/// The "AI" tab: connect a provider (bring your own key), pick a model, and
/// you're set — AI explain buttons then appear next to items in Reclaim and
/// My Mac. Nothing here changes your Mac; it only configures the assistant.
struct AIView: View {
    @EnvironmentObject var ai: AISettings
    @State private var keyDraft = ""
    @State private var testing = false
    @State private var testResult: TestResult?

    enum TestResult { case ok, fail(String) }

    private var provider: AIProvider { ai.activeProvider }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                providerTabs
                keySection
                modelSection
                if ai.hasKey(provider) { testSection }
                privacyNote
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(28)
        }
        .navigationTitle("AI Assistant")
        .frame(maxWidth: .infinity)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title).foregroundStyle(.tint)
                Text("Ask AI about anything on your Mac").font(.title2.weight(.semibold))
            }
            Text("Connect your own account from OpenAI, Anthropic, or Google. Once connected, a ✨ button appears next to items in Reclaim and My Mac — click it to ask “What is this, and is it safe to delete?” You use your own key, so you're in control of cost and privacy.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if ai.isReady {
                Label("Connected to \(provider.short) — look for the ✨ button next to items.",
                      systemImage: "checkmark.seal.fill")
                    .font(.callout).foregroundStyle(.green)
            }
        }
    }

    // MARK: Provider tabs

    private var providerTabs: some View {
        HStack(spacing: 8) {
            ForEach(AIProvider.allCases) { p in
                let active = provider == p
                Button {
                    ai.activeProvider = p; keyDraft = ""; testResult = nil
                } label: {
                    HStack(spacing: 6) {
                        if ai.hasKey(p) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        Text(p.short)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(active ? Color.accentColor.opacity(0.15) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(active ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Key

    @ViewBuilder private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(provider.displayName) API key").font(.headline)
            if ai.hasKey(provider) {
                HStack(spacing: 10) {
                    Label("Key saved", systemImage: "key.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Replace") { ai.setKey("", for: provider); keyDraft = ""; testResult = nil }
                        .buttonStyle(.link)
                    Button("Remove", role: .destructive) { ai.setKey("", for: provider); keyDraft = ""; testResult = nil }
                        .buttonStyle(.link)
                }
            } else {
                HStack(spacing: 8) {
                    SecureField(provider.keyPlaceholder, text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        ai.setKey(keyDraft, for: provider); keyDraft = ""; testResult = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: 6) {
                    Text(provider.keySteps).font(.caption).foregroundStyle(.secondary)
                    Link("Get a key ↗", destination: provider.keyConsoleURL).font(.caption)
                }
            }
        }
    }

    // MARK: Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model").font(.headline)
            ForEach(provider.models) { m in
                let selected = ai.model(for: provider) == m.id
                Button { ai.setModel(m.id, for: provider) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.name).fontWeight(.medium)
                            Text(m.blurb).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Test

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await testConnection() }
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("Test connection") }
                }
                .buttonStyle(.bordered).disabled(testing)
                switch testResult {
                case .ok: Label("Works! You're ready.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                case .fail(let m): Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption).lineLimit(2)
                case nil: EmptyView()
                }
            }
        }
    }

    private func testConnection() async {
        testing = true; testResult = nil
        let p = provider
        guard let key = ai.key(for: p) else { testResult = .fail("No key saved."); testing = false; return }
        do {
            _ = try await AIClient.explain(provider: p, model: ai.model(for: p), key: key,
                                           system: "You are a connection test.", user: "Reply with the single word: OK")
            testResult = .ok
        } catch {
            testResult = .fail((error as? AIError)?.errorDescription ?? error.localizedDescription)
        }
        testing = false
    }

    // MARK: Privacy

    private var privacyNote: some View {
        Label {
            Text("Your key is stored in your Mac's Keychain. Reclaim only sends an item's details — name, size, location, and type — to your chosen provider, never the file's contents. The AI advises; it never deletes anything.")
                .font(.caption).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "lock.shield").foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
