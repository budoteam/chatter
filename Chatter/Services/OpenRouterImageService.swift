import Foundation

/// Talks to the OpenRouter API (https://openrouter.ai) using the Bearer API
/// key stored in the keychain. Deliberately narrow: image generation through
/// the OpenAI-compatible chat-completions endpoint plus listing the models
/// capable of it — OpenRouter is not a chat provider here.
struct OpenRouterImageService {
    static let defaultBaseURL = URL(string: "https://openrouter.ai")!

    var baseURL: URL
    var session: URLSession
    /// Test seam: when set, used instead of the keychain key.
    var apiKeyOverride: String?

    init(baseURL: URL = OpenRouterImageService.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    enum ServiceError: LocalizedError {
        case missingAPIKey
        case noModelConfigured
        case http(Int, String)
        case decoding(String)
        case server(String)
        /// The model answered but returned no image payload.
        case noImages

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No OpenRouter API key set. Add one in Settings."
            case .noModelConfigured:
                return "No image model selected. Pick one in Settings → OpenRouter."
            case .http(let code, let body):
                return "OpenRouter request failed (\(code)). \(body)"
            case .decoding(let detail):
                return "Could not read OpenRouter response: \(detail)"
            case .server(let message):
                return "OpenRouter error: \(message)"
            case .noImages:
                return "The image model returned no image."
            }
        }
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        // Sanitize on load too, so keys stored with stray whitespace keep
        // working without re-entry (same lesson as the Ollama key).
        let storedKey = apiKeyOverride ?? KeychainService.loadOpenRouterAPIKey()
        guard let key = storedKey?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ServiceError.missingAPIKey
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - Image generation

    /// Generates image(s) for `prompt` with the configured model and returns
    /// them as raw Base64 payloads (no `data:` prefix). `images` are optional
    /// Base64 input images for editing (image-to-image). Non-streaming: image
    /// models return the whole payload in one response.
    func generateImages(prompt: String, images: [String] = []) async throws -> [String] {
        let model = AppSettings.imageGenModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw ServiceError.noModelConfigured }

        var content: [OpenRouterChatRequest.Message.Part] = [.text(prompt)]
        content += images.map { .imageBase64($0) }
        let request = OpenRouterChatRequest(
            model: model,
            messages: [.init(role: "user", content: content)],
            modalities: ["image", "text"],
            stream: false
        )
        let body = try JSONEncoder().encode(request)
        let data = try await performRequest(
            path: "/api/v1/chat/completions", method: "POST", httpBody: body
        )

        let response: OpenRouterChatResponse
        do {
            response = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
        if let apiError = response.error {
            throw ServiceError.server(apiError.message)
        }

        let images = (response.choices ?? []).flatMap { choice -> [String] in
            (choice.message?.images ?? []).compactMap { Self.base64Payload(from: $0.imageURL?.url) }
        }
        guard !images.isEmpty else { throw ServiceError.noImages }
        return images
    }

    /// Extracts the Base64 payload from a `data:image/…;base64,<payload>` URL;
    /// tolerates an already-raw payload.
    private static func base64Payload(from url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        guard url.hasPrefix("data:") else { return url }
        guard let comma = url.firstIndex(of: ",") else { return nil }
        let payload = String(url[url.index(after: comma)...])
        return payload.isEmpty ? nil : payload
    }

    // MARK: - Model listing

    /// Models whose output modalities include "image" — the candidates for
    /// the Settings image-model picker. Sorted by display name.
    func listImageModels() async throws -> [OpenRouterImageModel] {
        let data = try await performRequest(path: "/api/v1/models", method: "GET")
        let decoded: OpenRouterModelsResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
        return (decoded.data ?? [])
            .filter { $0.architecture?.outputModalities?.contains("image") == true }
            .map { OpenRouterImageModel(id: $0.id, name: $0.name ?? $0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Helpers

    /// makeRequest + send + status check in one spot, with a single retry on
    /// HTTP 401 after dropping the cached API key: the key syncs via iCloud
    /// Keychain, so a change or revoke on another device would otherwise keep
    /// failing until the app restarts (same pattern as OllamaService).
    private func performRequest(path: String, method: String, httpBody: Data? = nil) async throws -> Data {
        do {
            return try await send(path: path, method: method, httpBody: httpBody)
        } catch ServiceError.http(401, _) {
            KeychainService.invalidateOpenRouterCache()
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

// MARK: - Wire types

/// A model in the Settings image-model picker.
struct OpenRouterImageModel: Identifiable, Hashable {
    let id: String
    let name: String
}

private struct OpenRouterChatRequest: Encodable {
    struct Message: Encodable {
        /// OpenAI-style multimodal content part: text or a Base64 data-URL image.
        enum Part: Encodable {
            case text(String)
            case imageBase64(String)

            private struct TextPart: Encodable {
                let type = "text"
                let text: String
            }
            private struct ImagePart: Encodable {
                struct ImageURL: Encodable { let url: String }
                let type = "image_url"
                let image_url: ImageURL
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let text):
                    try container.encode(TextPart(text: text))
                case .imageBase64(let base64):
                    try container.encode(ImagePart(
                        image_url: .init(url: "data:image/jpeg;base64,\(base64)")
                    ))
                }
            }
        }
        var role: String
        var content: [Part]
    }
    var model: String
    var messages: [Message]
    var modalities: [String]
    var stream: Bool
}

private struct OpenRouterChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            struct Image: Decodable {
                struct ImageURL: Decodable {
                    var url: String?
                }
                var imageURL: ImageURL?

                enum CodingKeys: String, CodingKey {
                    case imageURL = "image_url"
                }
            }
            var images: [Image]?
        }
        var message: Message?
    }
    struct APIError: Decodable {
        var message: String
    }
    var choices: [Choice]?
    /// OpenRouter reports request-level failures in-band as `{"error": …}`.
    var error: APIError?
}

private struct OpenRouterModelsResponse: Decodable {
    struct Model: Decodable {
        struct Architecture: Decodable {
            var outputModalities: [String]?

            enum CodingKeys: String, CodingKey {
                case outputModalities = "output_modalities"
            }
        }
        var id: String
        var name: String?
        var architecture: Architecture?
    }
    var data: [Model]?
}
