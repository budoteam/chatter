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
        let data = try await performRequest(path: "/api/tags", method: "GET")
        do {
            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return decoded.models.sorted { $0.name < $1.name }
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
    }

    func modelCapabilities(model: String) async throws -> [String] {
        let body = try JSONEncoder().encode(OllamaShowRequest(model: model))
        let data = try await performRequest(path: "/api/show", method: "POST", httpBody: body)
        do {
            return try JSONDecoder().decode(OllamaShowResponse.self, from: data).capabilities ?? []
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Web research

    func webSearch(query: String, maxResults: Int) async throws -> OllamaWebSearchResponse {
        let body = try JSONEncoder().encode(
            OllamaWebSearchRequest(query: query, maxResults: maxResults)
        )
        let data = try await performRequest(path: "/api/web_search", method: "POST", httpBody: body)
        do {
            return try JSONDecoder().decode(OllamaWebSearchResponse.self, from: data)
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
    }

    func webFetch(url: String) async throws -> OllamaWebFetchResponse {
        let body = try JSONEncoder().encode(OllamaWebFetchRequest(url: url))
        let data = try await performRequest(path: "/api/web_fetch", method: "POST", httpBody: body)
        do {
            return try JSONDecoder().decode(OllamaWebFetchResponse.self, from: data)
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Chat streaming

    func streamChat(
        model: String,
        messages: [OllamaChatMessage],
        tools: [OllamaTool],
        temperature: Double,
        think: OllamaThinkValue?
    ) -> AsyncThrowingStream<OllamaChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamChatOnce(
                        model: model, messages: messages, tools: tools,
                        temperature: temperature, think: think,
                        continuation: continuation
                    )
                } catch ServiceError.http(401, _) {
                    // The key syncs via iCloud Keychain — a change/revoke on
                    // another device would otherwise 401 until app restart.
                    // No chunks were yielded yet (401 fails pre-stream), so a
                    // single retry with a freshly-read key is safe.
                    KeychainService.invalidateCache()
                    do {
                        try await streamChatOnce(
                            model: model, messages: messages, tools: tools,
                            temperature: temperature, think: think,
                            continuation: continuation
                        )
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One streaming attempt: POST /api/chat, yield decoded NDJSON chunks.
    private func streamChatOnce(
        model: String,
        messages: [OllamaChatMessage],
        tools: [OllamaTool],
        temperature: Double,
        think: OllamaThinkValue?,
        continuation: AsyncThrowingStream<OllamaChatChunk, Error>.Continuation
    ) async throws {
        var request = try makeRequest(path: "/api/chat", method: "POST")
        let body = OllamaChatRequest(
            model: model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            stream: true,
            think: think,
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
        var didLogUndecodableLine = false
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8) else { continue }
            guard let chunk = try? decoder.decode(OllamaChatStreamLine.self, from: data)
            else {
                // Schema drift or a stray non-JSON line in a 200 stream would
                // otherwise degrade to a silently empty answer — log the
                // first drop per stream.
                if !didLogUndecodableLine {
                    didLogUndecodableLine = true
                    AppLogger.api.error("Skipping undecodable /api/chat stream line: \(trimmed.prefix(200), privacy: .public)")
                }
                continue
            }

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
    }

    // MARK: - Helpers

    /// makeRequest + send + status check in one spot, with a single retry on
    /// HTTP 401 after dropping the cached API key: the key syncs via iCloud
    /// Keychain, so a change or revoke on another device would otherwise keep
    /// failing until the app restarts.
    private func performRequest(path: String, method: String, httpBody: Data? = nil) async throws -> Data {
        do {
            return try await send(path: path, method: method, httpBody: httpBody)
        } catch ServiceError.http(401, _) {
            KeychainService.invalidateCache()
            return try await send(path: path, method: method, httpBody: httpBody)
        }
    }

    private func send(path: String, method: String, httpBody: Data?) async throws -> Data {
        var request = try makeRequest(path: path, method: method)
        request.httpBody = httpBody
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return data
    }

    private static func validate(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw ServiceError.http(http.statusCode, String(body.prefix(300)))
        }
    }
}
