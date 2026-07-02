import Foundation

/// Abstraction over the Ollama Cloud HTTP API so views/engine can be tested
/// against a mock.
protocol OllamaServiceProtocol {
    /// Available models from `/api/tags`.
    func listModels() async throws -> [OllamaModel]

    /// Streams a chat completion from `/api/chat`. Emits incremental content
    /// deltas and a final chunk carrying any tool calls + `done`.
    func streamChat(
        model: String,
        messages: [OllamaChatMessage],
        tools: [OllamaTool],
        temperature: Double
    ) -> AsyncThrowingStream<OllamaChatChunk, Error>
}
