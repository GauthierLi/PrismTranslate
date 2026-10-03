import Foundation
import Combine

struct OllamaModel: Identifiable, Hashable {
    let name: String

    var id: String { name }
}

enum OllamaError: LocalizedError, Equatable {
    case invalidURL
    case serviceUnavailable(String)
    case http(Int, String)
    case decoding(String)
    case emptyResponse
    case noModelSelected

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Ollama 本地接口地址无效。"
        case .serviceUnavailable(let message):
            return "无法连接 Ollama，请确认 Ollama 已启动。\(message.isEmpty ? "" : "（\(message)）")"
        case .http(let code, let body):
            let snippet = body.prefix(300)
            return "Ollama 请求失败（HTTP \(code)）：\(snippet)"
        case .decoding(let message):
            return "解析 Ollama 返回内容失败：\(message)"
        case .emptyResponse:
            return "Ollama 返回了空翻译结果。"
        case .noModelSelected:
            return "请先在设置中选择一个 Ollama 模型。"
        }
    }
}

struct OllamaClient {
    static let defaultBaseURL = "http://127.0.0.1:11434"

    let baseURL: String
    private let session: URLSession

    init(baseURL: String = OllamaClient.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    static func parseModels(data: Data) throws -> [OllamaModel] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawModels = json["models"] as? [[String: Any]]
        else {
            throw OllamaError.decoding(String(data: data, encoding: .utf8)?.prefix(300).description ?? "unknown")
        }

        return rawModels.compactMap { rawModel in
            guard let rawName = rawModel["name"] as? String else { return nil }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : OllamaModel(name: name)
        }
    }

    static func parseChatResponse(data: Data) throws -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw OllamaError.decoding(String(data: data, encoding: .utf8)?.prefix(300).description ?? "unknown")
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OllamaError.emptyResponse }
        return trimmed
    }

    static func makeChatRequest(
        baseURL: String,
        model: String,
        systemPrompt: String,
        userText: String
    ) throws -> URLRequest {
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModel.isEmpty else { throw OllamaError.noModelSelected }

        var origin = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while origin.hasSuffix("/") { origin.removeLast() }
        guard let url = URL(string: origin + "/api/chat") else {
            throw OllamaError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": selectedModel,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func listModels() async throws -> [OllamaModel] {
        guard let url = URL(string: normalizedBaseURL + "/api/tags") else {
            throw OllamaError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)
            try Self.checkHTTP(response, data: data)
            return try Self.parseModels(data: data)
        } catch let error as OllamaError {
            throw error
        } catch {
            throw OllamaError.serviceUnavailable(error.localizedDescription)
        }
    }

    func translate(text: String, systemPrompt: String, model: String) async throws -> String {
        let request = try Self.makeChatRequest(
            baseURL: normalizedBaseURL,
            model: model,
            systemPrompt: systemPrompt,
            userText: text
        )

        do {
            let (data, response) = try await session.data(for: request)
            try Self.checkHTTP(response, data: data)
            return try Self.parseChatResponse(data: data)
        } catch let error as OllamaError {
            throw error
        } catch {
            throw OllamaError.serviceUnavailable(error.localizedDescription)
        }
    }

    private var normalizedBaseURL: String {
        var origin = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while origin.hasSuffix("/") { origin.removeLast() }
        return origin
    }

    private static func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.http(http.statusCode, body)
        }
    }
}

@MainActor
final class OllamaModelStore: ObservableObject {
    @Published private(set) var models: [OllamaModel] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let client: OllamaClient

    init(client: OllamaClient = OllamaClient()) {
        self.client = client
    }

    func refresh() async throws -> [OllamaModel] {
        guard !isRefreshing else { return models }

        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            let discovered = try await client.listModels()
            models = discovered
            return discovered
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }
}
