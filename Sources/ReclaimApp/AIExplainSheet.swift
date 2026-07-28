import SwiftUI

/// The popup that answers "What is this, and is it safe to delete?" for one
/// item. Streams the answer in with a typewriter reveal so it reads like the
/// assistant is typing back.
struct AIExplainSheet: View {
    @EnvironmentObject var ai: AISettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: AppModel.AIRequest

    @State private var answer = ""
    @State private var shown = 0
    @State private var loading = true
    @State private var error: String?
    private let ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private var provider: AIProvider { ai.activeProvider }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 480, height: 380)
        .task { await ask() }
        .onReceive(ticker) { _ in
            guard error == nil, shown < answer.count else { return }
            shown = reduceMotion ? answer.count : min(answer.count, shown + 2)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
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

    @ViewBuilder private var content: some View {
        if loading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Asking \(provider.short)…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
                Text(error).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
                Button("Try again") { Task { await ask() } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else {
            ScrollView {
                Text(String(answer.prefix(shown)))
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private var footer: some View {
        Text("AI can be wrong — it advises, you decide. Nothing is deleted from here.")
            .font(.caption2).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func ask() async {
        loading = true; error = nil; answer = ""; shown = 0
        let p = provider
        guard let key = ai.key(for: p) else {
            error = AIError.notConfigured.errorDescription; loading = false; return
        }
        do {
            let text = try await AIClient.explain(
                provider: p, model: ai.model(for: p), key: key,
                system: request.system, user: request.user)
            answer = text; loading = false
        } catch {
            self.error = (error as? AIError)?.errorDescription ?? error.localizedDescription
            loading = false
        }
    }
}
