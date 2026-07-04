import Foundation

/// Talks to the Ollama Cloud HTTP API (https://ollama.com) using the Bearer API
/// key stored in the keychain.
struct OllamaService: OllamaServiceProtocol {
    static let defaultBaseURL = URL(string: "https://ollama.com")!

    var baseURL: URL
    var session: URLSession

    init(baseURL: URL = OllamaService.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    enum ServiceError: LocalizedError {
        case missingAPIKey
        case http(Int, String)
        case decoding(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Ollama API key set. Add one in Settings."
            case .http(let code, let body):
                return "Ollama request failed (\(code)). \(body)"
            case .decoding(let detail):
                return "Could not read Ollama response: \(detail)"
            case .server(let message):
                return "Ollama error: \(message)"
            }
        }
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        // Sanitize on load too, so keys stored with stray whitespace by older
        // builds keep working without re-entry.
        guard let key = KeychainService.loadAPIKey()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ServiceError.missingAPIKey
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - Models

    func listModels() async throws -> [OllamaModel] {
        let request = try makeRequest(path: "/api/tags", method: "GET")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        do {
            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return decoded.models.sorted { $0.name < $1.name }
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
    }

    func modelCapabilities(model: String) async throws -> [String] {
        var request = try makeRequest(path: "/api/show", method: "POST")
        request.httpBody = try JSONEncoder().encode(OllamaShowRequest(model: model))
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        do {
            return try JSONDecoder().decode(OllamaShowResponse.self, from: data).capabilities ?? []
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Chat streaming

    func streamChat(
        model: String,
        messages: [OllamaChatMessage],
        tools: [OllamaTool],
        temperature: Double
    ) -> AsyncThrowingStream<OllamaChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try makeRequest(path: "/api/chat", method: "POST")
                    let body = OllamaChatRequest(
                        model: model,
                        messages: messages,
                        tools: tools.isEmpty ? nil : tools,
                        stream: true,
                        options: .init(temperature: temperature)
                    )
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        // Read (a prefix of) the body so the error is actionable.
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 500 { break }
                        }
                        throw ServiceError.http(http.statusCode, String(body.prefix(300)))
                    }

                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty,
                              let data = trimmed.data(using: .utf8) else { continue }
                        guard let chunk = try? decoder.decode(OllamaChatStreamLine.self, from: data)
                        else { continue }

                        if let apiError = chunk.error {
                            throw ServiceError.server(apiError)
                        }
                        if let calls = chunk.message?.toolCalls, !calls.isEmpty {
                            continuation.yield(.toolCalls(calls))
                        }
                        if let thinking = chunk.message?.thinking, !thinking.isEmpty {
                            continuation.yield(.thinking(thinking))
                        }
                        if let content = chunk.message?.content, !content.isEmpty {
                            continuation.yield(.delta(content))
                        }
                        if chunk.done == true {
                            continuation.yield(.done(reason: chunk.doneReason))
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private static func validate(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw ServiceError.http(http.statusCode, String(body.prefix(300)))
        }
    }
}
