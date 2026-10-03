import Foundation

@main
struct OllamaClientTests {
    static func main() throws {
        try testModelParser()
        try testChatResponseParser()
        try testChatRequestBuilder()
        testProviderConfiguration()
        print("Ollama contract tests passed")
    }

    private static func testModelParser() throws {
        let json = #"{"models":[{"name":"gemma3:1b"},{"name":"  "},{"name":"qwen3:8b"}]}"#
        let models = try OllamaClient.parseModels(data: Data(json.utf8))
        precondition(models.map(\.name) == ["gemma3:1b", "qwen3:8b"])

        let empty = try OllamaClient.parseModels(data: Data(#"{"models":[]}"#.utf8))
        precondition(empty.isEmpty)
    }

    private static func testChatResponseParser() throws {
        let json = #"{"message":{"content":"  你好  "}}"#
        let response = try OllamaClient.parseChatResponse(data: Data(json.utf8))
        precondition(response == "你好")

        do {
            _ = try OllamaClient.parseChatResponse(data: Data(#"{"message":{"content":"  "}}"#.utf8))
            preconditionFailure("Expected empty response to throw")
        } catch OllamaError.emptyResponse {
            // Expected.
        }
    }

    private static func testChatRequestBuilder() throws {
        let request = try OllamaClient.makeChatRequest(
            baseURL: "http://127.0.0.1:11434",
            model: "gemma3:1b",
            systemPrompt: "Translate.",
            userText: "Hello"
        )

        precondition(request.httpMethod == "POST")
        precondition(request.url == URL(string: "http://127.0.0.1:11434/api/chat"))

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(body["model"] as? String == "gemma3:1b")
        precondition(body["stream"] as? Bool == false)
        let messages = body["messages"] as! [[String: String]]
        precondition(messages[0]["role"] == "system")
        precondition(messages[0]["content"] == "Translate.")
        precondition(messages[1]["role"] == "user")
        precondition(messages[1]["content"] == "Hello")
    }

    private static func testProviderConfiguration() {
        precondition(AppSettings.isConfigured(
            provider: .ollama,
            apiKey: "",
            baseURL: "",
            model: "gemma3:1b"
        ))
        precondition(!AppSettings.isConfigured(
            provider: .ollama,
            apiKey: "",
            baseURL: "",
            model: ""
        ))
        precondition(AppSettings.isConfigured(
            provider: .openai,
            apiKey: "key",
            baseURL: "https://example.com/v1",
            model: "model"
        ))
        precondition(!AppSettings.isConfigured(
            provider: .openai,
            apiKey: "",
            baseURL: "https://example.com/v1",
            model: "model"
        ))
    }
}
