import Foundation

enum TranslationError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)
    case emptyResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置 API Key 或接口地址，请在设置中填写。"
        case .badURL: return "接口地址无效。"
        case .http(let code, let body):
            let snippet = body.prefix(300)
            return "请求失败（HTTP \(code)）：\(snippet)"
        case .emptyResponse: return "接口返回为空。"
        case .decoding(let msg): return "解析返回内容失败：\(msg)"
        }
    }
}

/// Handles translation via either OpenAI-compatible or Anthropic-compatible chat APIs.
struct Translator {

    let provider: ProviderKind
    let baseURL: String
    let apiKey: String
    let model: String

    init(settings: AppSettings) {
        self.provider = settings.provider
        self.baseURL = settings.baseURL.trimmingCharacters(in: .whitespaces)
        self.apiKey = settings.apiKey.trimmingCharacters(in: .whitespaces)
        self.model = settings.model.trimmingCharacters(in: .whitespaces)
    }

    private func systemPrompt(source: String, target: String) -> String {
        let targetLabel = LanguageOption.label(for: target)
        let sourceClause: String
        if source == "auto" {
            sourceClause = "Detect the source language automatically."
        } else {
            sourceClause = "The source text is in \(LanguageOption.label(for: source))."
        }
        return """
        You are a professional translation engine. \(sourceClause)
        Translate the user's text into \(targetLabel).
        Rules:
        - Output ONLY the translated text, with no explanations, quotes, or labels.
        - Preserve line breaks and meaning; keep it natural and fluent.
        - Do not answer questions in the text; translate them literally.
        """
    }

    func translate(_ text: String, source: String, target: String) async throws -> String {
        guard !apiKey.isEmpty, !baseURL.isEmpty else { throw TranslationError.notConfigured }
        switch provider {
        case .openai:
            return try await translateOpenAI(text, source: source, target: target)
        case .anthropic:
            return try await translateAnthropic(text, source: source, target: target)
        }
    }

    /// Build the final endpoint URL.
    /// Accepts a base URL that is either the API root (e.g. ".../v1")
    /// or already the full endpoint (e.g. ".../v1/chat/completions").
    private func endpoint(path: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }

        // If the user already pasted the full endpoint, use it as-is.
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if base.hasSuffix("/" + suffix) || base.hasSuffix(suffix) {
            guard let url = URL(string: base) else { throw TranslationError.badURL }
            return url
        }

        guard let url = URL(string: base + path) else { throw TranslationError.badURL }
        return url
    }

    // MARK: - OpenAI (chat/completions)

    private func translateOpenAI(_ text: String, source: String, target: String) async throws -> String {
        let url = try endpoint(path: "/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": systemPrompt(source: source, target: target)],
                ["role": "user", "content": text],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.checkHTTP(resp, data)

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw TranslationError.decoding(String(data: data, encoding: .utf8)?.prefix(300).description ?? "unknown")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.emptyResponse }
        return trimmed
    }

    // MARK: - Anthropic (messages)

    private func translateAnthropic(_ text: String, source: String, target: String) async throws -> String {
        let url = try endpoint(path: "/messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "temperature": 0.2,
            "system": systemPrompt(source: source, target: target),
            "messages": [
                ["role": "user", "content": text],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.checkHTTP(resp, data)

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contentArr = json["content"] as? [[String: Any]]
        else {
            throw TranslationError.decoding(String(data: data, encoding: .utf8)?.prefix(300).description ?? "unknown")
        }
        // Concatenate all text blocks.
        let out = contentArr.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.emptyResponse }
        return trimmed
    }

    private static func checkHTTP(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranslationError.http(http.statusCode, body)
        }
    }
}
