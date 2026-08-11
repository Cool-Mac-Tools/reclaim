import Foundation
import Security
import SwiftUI

// MARK: - Providers

/// The three AI providers a user can bring their own key for. Reclaim only asks
/// for a short plain-language explanation, so there's no tool-use — just a
/// single-shot text completion.
enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case anthropic, openai, google
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic — Claude"
        case .openai:    "OpenAI — GPT"
        case .google:    "Google — Gemini"
        }
    }
    var short: String {
        switch self { case .anthropic: "Claude"; case .openai: "OpenAI"; case .google: "Gemini" }
    }
    var keyConsoleURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai:    URL(string: "https://platform.openai.com/api-keys")!
        case .google:    URL(string: "https://aistudio.google.com/apikey")!
        }
    }
    var keyPlaceholder: String {
        switch self { case .anthropic: "sk-ant-…"; case .openai: "sk-…"; case .google: "AIza…" }
    }
    /// How to get a key, in one line.
    var keySteps: String {
        switch self {
        case .anthropic: "Sign in at console.anthropic.com → API Keys → Create Key."
        case .openai:    "Sign in at platform.openai.com → API keys → Create new secret key."
        case .google:    "Open Google AI Studio → Get API key → Create."
        }
    }

    struct Model: Identifiable, Hashable { let id: String; let name: String; let blurb: String }
    var models: [Model] {
        switch self {
        case .anthropic: [
            .init(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", blurb: "Fast & inexpensive — recommended"),
            .init(id: "claude-sonnet-5", name: "Claude Sonnet 5", blurb: "Balanced"),
            .init(id: "claude-opus-4-8", name: "Claude Opus 4.8", blurb: "Most capable"),
        ]
        case .openai: [
            .init(id: "gpt-5-nano", name: "GPT-5 nano", blurb: "Cheapest & fastest"),
            .init(id: "gpt-5-mini", name: "GPT-5 mini", blurb: "Balanced — recommended"),
            .init(id: "gpt-5", name: "GPT-5", blurb: "Most capable"),
        ]
        case .google: [
            .init(id: "gemini-2.5-flash-lite", name: "Gemini 2.5 Flash-Lite", blurb: "Cheapest & fastest"),
            .init(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", blurb: "Balanced — recommended"),
            .init(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", blurb: "Most capable"),
        ]
        }
    }
    var defaultModel: String {
        switch self {
        case .anthropic: "claude-haiku-4-5"; case .openai: "gpt-5-mini"; case .google: "gemini-2.5-flash"
        }
    }
}

// MARK: - Keychain (BYOK keys live here, never in a file)

enum AIKeychain {
    static let service = "com.reclaimac.app.ai"

    static func set(_ value: String, account: String) {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

// MARK: - Settings

/// Per-provider key (Keychain) + model (UserDefaults) + the active provider.
@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()

    @Published var activeProvider: AIProvider {
        didSet { UserDefaults.standard.set(activeProvider.rawValue, forKey: providerKey) }
    }
    /// Bumped whenever a key is added/removed so views re-render.
    @Published private var revision = 0

    private let providerKey = "reclaim.ai.provider"
    private func account(_ p: AIProvider) -> String { "key.\(p.rawValue)" }
    private func modelKey(_ p: AIProvider) -> String { "reclaim.ai.model.\(p.rawValue)" }

    private init() {
        let saved = UserDefaults.standard.string(forKey: providerKey)
        activeProvider = AIProvider(rawValue: saved ?? "") ?? .anthropic
    }

    func key(for p: AIProvider) -> String? {
        _ = revision
        let k = AIKeychain.get(account(p))
        return (k?.isEmpty ?? true) ? nil : k
    }
    func hasKey(_ p: AIProvider) -> Bool { key(for: p) != nil }
    func setKey(_ value: String, for p: AIProvider) {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { AIKeychain.delete(account(p)) } else { AIKeychain.set(t, account: account(p)) }
        revision += 1
    }
    func model(for p: AIProvider) -> String {
        UserDefaults.standard.string(forKey: modelKey(p)) ?? p.defaultModel
    }
    func setModel(_ m: String, for p: AIProvider) {
        UserDefaults.standard.set(m, forKey: modelKey(p)); objectWillChange.send()
    }

    /// AI features light up only when the active provider has a key.
    var isReady: Bool { hasKey(activeProvider) }
}

// MARK: - Client

enum AIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .notConfigured: "No API key set. Open the AI tab to connect a provider."
        case .http(let code, let msg): "The provider returned an error (\(code)). \(msg)"
        case .empty: "The model returned an empty response. Try again or pick another model."
        }
    }
}

/// One turn in a conversation. `assistant` turns carry the model's prior
/// replies so follow-up questions have context.
struct AIMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

/// Text completion against the chosen provider. Metadata only — file contents
/// never leave the Mac.
enum AIClient {
    /// One-shot convenience: a single user message, no history.
    static func explain(provider: AIProvider, model: String, key: String,
                        system: String, user: String) async throws -> String {
        try await chat(provider: provider, model: model, key: key, system: system,
                       messages: [AIMessage(role: .user, text: user)])
    }

    /// Multi-turn chat so the explain popup can take follow-up questions.
    static func chat(provider: AIProvider, model: String, key: String,
                     system: String, messages: [AIMessage]) async throws -> String {
        switch provider {
        case .openai:    try await openaiChat(model, key, system, messages)
        case .anthropic: try await anthropicChat(model, key, system, messages)
        case .google:    try await googleChat(model, key, system, messages)
        }
    }

    private static func post(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw AIError.http(code, String(data: data, encoding: .utf8)?.prefix(300).description ?? "")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func openaiChat(_ model: String, _ key: String, _ system: String, _ msgs: [AIMessage]) async throws -> String {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        messages += msgs.map { ["role": $0.role.rawValue, "content": $0.text] }
        let json = try await post(
            URL(string: "https://api.openai.com/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(key)"],
            body: ["model": model, "messages": messages])
        let choices = json["choices"] as? [[String: Any]]
        let text = (choices?.first?["message"] as? [String: Any])?["content"] as? String
        guard let text, !text.isEmpty else { throw AIError.empty }
        return text
    }

    private static func anthropicChat(_ model: String, _ key: String, _ system: String, _ msgs: [AIMessage]) async throws -> String {
        let messages = msgs.map { ["role": $0.role.rawValue, "content": $0.text] }
        let json = try await post(
            URL(string: "https://api.anthropic.com/v1/messages")!,
            headers: ["x-api-key": key, "anthropic-version": "2023-06-01"],
            body: ["model": model, "max_tokens": 1024, "system": system, "messages": messages])
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.empty }
        return text
    }

    private static func googleChat(_ model: String, _ key: String, _ system: String, _ msgs: [AIMessage]) async throws -> String {
        // Gemini uses role "model" for assistant turns.
        let contents = msgs.map { m -> [String: Any] in
            ["role": m.role == .assistant ? "model" : "user", "parts": [["text": m.text]]]
        }
        let json = try await post(
            URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!,
            headers: ["x-goog-api-key": key],
            body: ["system_instruction": ["parts": [["text": system]]], "contents": contents])
        let candidates = json["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.empty }
        return text
    }
}

// MARK: - Reusable ✨ button

/// The little "Ask AI" affordance shown next to items once a provider is
/// connected. Tapping opens the explain popup.
struct AISparkButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.callout).foregroundStyle(.tint)
        }
        .buttonStyle(.borderless)
        .help("Ask AI: what is this, and is it safe to delete?")
    }
}

// MARK: - Prompt

/// Builds the (system, user) prompt for explaining an item. Metadata only.
enum AIPrompt {
    static let system = """
    You are Reclaim's storage assistant, embedded in a Mac cleanup app. Given \
    an item's metadata (you cannot see file contents), explain in plain language \
    what it most likely is and whether it's safe to delete. Be concise — 2 to 4 \
    short sentences, friendly and direct. Rules: base your answer only on the \
    metadata provided; if it's personal or user-created content, or system/\
    protected data, say so and never claim it is 100% safe to delete — flag what \
    could be lost. You are advising only; you never delete anything.
    """

    static func user(name: String, location: String, size: String, tier: String,
                     detail: String, impact: String, recurrence: String) -> String {
        var lines = ["Item: \(name)", "Location: \(location)", "Size: \(size)", "Safety tier: \(tier)"]
        if !detail.isEmpty { lines.append("What Reclaim knows: \(detail)") }
        if !impact.isEmpty { lines.append("Impact if removed: \(impact)") }
        if !recurrence.isEmpty { lines.append("Comes back: \(recurrence)") }
        lines.append("\nQuestion: What is this, and is it safe to delete?")
        return lines.joined(separator: "\n")
    }

    /// System prompt for the whole-Mac "what should I clean?" summary.
    static let summarySystem = """
    You are Reclaim's storage advisor. You're given a summary of a Mac's storage \
    scan — categories, the largest items found, sizes, and safety tiers (you \
    never see file contents). Give a short, friendly, PRIORITIZED plan: what's \
    safe to reclaim first and why, what to review carefully, and what to leave \
    alone. Be specific and cite the numbers from the data. Keep it to a short \
    bulleted list or 4–8 sentences. You advise only — the user clicks to act.
    """
}

/// Builds extra, METADATA-ONLY context for the explain popup: when an item was
/// last used, and — for a folder — what's inside it (names and sizes only,
/// never file contents). Runs off the main thread; keeps the privacy promise.
enum AIContext {
    static func enrich(path: String) -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return "" }
        var lines: [String] = []
        let url = URL(fileURLWithPath: path)
        if let v = try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey]) {
            if let acc = v.contentAccessDate {
                lines.append("Last opened \(Int(Date().timeIntervalSince(acc) / 86400)) days ago.")
            }
            if let mod = v.contentModificationDate {
                lines.append("Last changed \(Int(Date().timeIntervalSince(mod) / 86400)) days ago.")
            }
        }
        if isDir.boolValue {
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
            let entries = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
            let sized = entries.map { u -> (name: String, bytes: Int64, dir: Bool) in
                let v = try? u.resourceValues(forKeys: keys)
                return (u.lastPathComponent, Int64(v?.totalFileAllocatedSize ?? 0), v?.isDirectory ?? false)
            }.sorted { $0.bytes > $1.bytes }
            if !sized.isEmpty {
                lines.append("This folder holds \(entries.count) item(s). Largest:")
                for e in sized.prefix(8) {
                    lines.append("  • \(e.name)\(e.dir ? "/ (folder)" : "") — \(e.bytes > 0 ? Fmt.bytes(e.bytes) : "small")")
                }
            }
        }
        return lines.isEmpty ? "" : "\nLive details from the Mac:\n" + lines.joined(separator: "\n")
    }
}
