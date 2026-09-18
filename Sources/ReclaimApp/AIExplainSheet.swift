import SwiftUI

/// The AI popup. Opens by answering "What is this, and is it safe to delete?"
/// for one item — enriched with live, metadata-only context (folder contents,
/// last-used date) — then stays open as a chat so you can ask follow-ups
/// ("what breaks if I remove it?", "why is it so big?"). Metadata only; file
/// contents never leave the Mac.
struct AIExplainSheet: View {
    @EnvironmentObject var ai: AISettings
    @Environment(\.dismiss) private var dismiss
    let request: AppModel.AIRequest

    @State private var transcript: [AIMessage] = []   // what the user sees
    @State private var seededPrompt = ""              // full first-turn payload
    @State private var input = ""
    @State private var sending = false
    @State private var keyDraft = ""
    @State private var error: String?
    @FocusState private var inputFocused: Bool

    private var provider: AIProvider { ai.activeProvider }
    private var isSummary: Bool { request.contextPath == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if ai.isReady {
                transcriptView
                Divider()
                composer
            } else {
                setup
            }
        }
        .frame(width: 540, height: 500)
        .task { if ai.isReady { await start() } }
        .onChange(of: ai.activeProvider) { _, _ in
            keyDraft = ""
            if ai.isReady { Task { await start() } }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect AI to explain this item").font(.title3.weight(.semibold))
            Text("Bring your own API key. Your provider bills your usage directly. Reclaim sends this item's metadata, never its file contents.")
                .foregroundStyle(.secondary)
            Picker("Provider", selection: $ai.activeProvider) {
                ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
            }
            Text(provider.keySteps).font(.callout)
            Link("Get a \(provider.short) API key", destination: provider.keyConsoleURL)
            SecureField(provider.keyPlaceholder, text: $keyDraft).textFieldStyle(.roundedBorder)
            if let keyError = ai.keyError { Text(keyError).font(.caption).foregroundStyle(.orange) }
            Button("Save key & explain this item") {
                ai.setKey(keyDraft, for: provider)
                if ai.isReady { keyDraft = ""; Task { await start() } }
            }
            .buttonStyle(.borderedProminent)
            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Stored in your Mac's Keychain. You can replace or remove it in AI settings.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isSummary ? "wand.and.stars" : "sparkles").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.title).font(.headline).lineLimit(1)
                Text("\(provider.short) · \(ai.model(for: provider))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding(14)
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(transcript) { bubble($0) }
                    if sending { typingIndicator.id("typing") }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Retry") { Task { await send() } }.disabled(sending)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: transcript.count) { _, _ in
                withAnimation { proxy.scrollTo(transcript.last?.id, anchor: .bottom) }
            }
            .onChange(of: sending) { _, s in
                if s { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private func bubble(_ m: AIMessage) -> some View {
        if m.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(m.text)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint).font(.caption)
                Text(m.text).font(.callout).textSelection(.enabled)
                Spacer(minLength: 20)
            }
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking…").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField(isSummary ? "Ask about your storage…" : "Ask a follow-up…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(send)
                Button {
                    send()
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(sending || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("AI can be wrong — it advises, you decide. Nothing is deleted from here.")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - Conversation

    private func start() async {
        guard transcript.isEmpty else { return }
        // Build the full first-turn payload (with live enrichment for a real
        // item), but show the user a short, friendly question.
        var payload = request.user
        if let path = request.contextPath {
            let extra = await Task.detached { AIContext.enrich(path: path) }.value
            if !extra.isEmpty { payload += extra }
        }
        seededPrompt = payload
        transcript = [AIMessage(role: .user,
            text: isSummary ? "What should I clean, and why?" : "What is this, and is it safe to delete?")]
        await send(isFirst: true)
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !sending else { return }
        input = ""
        transcript.append(AIMessage(role: .user, text: text))
        Task { await send() }
    }

    private func send(isFirst: Bool = false) async {
        error = nil
        guard let key = ai.key(for: provider) else {
            error = AIError.notConfigured.errorDescription; return
        }
        sending = true
        // Reconstruct the API history: turn 0 carries the full seeded prompt,
        // the rest is the visible conversation verbatim.
        let apiMessages: [AIMessage] = transcript.enumerated().map { i, m in
            i == 0 ? AIMessage(role: .user, text: seededPrompt) : m
        }
        do {
            let reply = try await AIClient.chat(
                provider: provider, model: ai.model(for: provider), key: key,
                system: request.system, messages: apiMessages)
            transcript.append(AIMessage(role: .assistant, text: reply))
        } catch {
            self.error = (error as? AIError)?.errorDescription ?? error.localizedDescription
        }
        sending = false
        inputFocused = true
    }
}
