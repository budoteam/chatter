import Foundation

/// Abstraction over the Ollama Cloud HTTP API so views/engine can be tested
/// against a mock.
protocol OllamaServiceProtocol {
    /// Available models from `/api/tags`.
    func listModels() async throws -> [OllamaModel]

    /// Capabilities for a model from `/api/show`, e.g. ["completion", "tools",
    /// "vision"]. Used to gate features like image attachments.
    func modelCapabilities(model: String) async throws -> [String]

    /// Streams a chat completion from `/api/chat`. Emits incremental content
    /// deltas and a final chunk carrying any tool calls + `done`.
    func streamChat(
        model: String,
        messages: [OllamaChatMessage],
        tools: [OllamaTool],
        temperature: Double
    ) -> AsyncThrowingStream<OllamaChatChunk, Error>
}

extension OllamaServiceProtocol {
    /// Default: no capability info (mocks/tests). The real service overrides
    /// this with a `/api/show` call.
    func modelCapabilities(model: String) async throws -> [String] { [] }

    /// One-shot completion: runs a tool-less chat and returns the full
    /// assistant text, dropping `.thinking`/`.toolCalls` chunks. Bound to
    /// every conformer (real service and mocks) so features that don't need
    /// streaming don't re-implement the collect loop.
    ///
    /// The stream ends normally (no throw) when the consuming task is
    /// cancelled, so callers that care must check `Task.isCancelled` after.
    func complete(
        model: String,
        messages: [OllamaChatMessage],
        temperature: Double = 0
    ) async throws -> String {
        var text = ""
        for try await chunk in streamChat(
            model: model, messages: messages, tools: [], temperature: temperature
        ) {
            if case .delta(let piece) = chunk { text += piece }
        }
        return text
    }
}
