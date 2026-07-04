import Foundation

// MARK: - Model listing (/api/tags)

struct OllamaModel: Codable, Identifiable, Hashable {
    var name: String
    var model: String?
    var details: Details?

    var id: String { name }

    struct Details: Codable, Hashable {
        var family: String?
        var parameterSize: String?

        enum CodingKeys: String, CodingKey {
            case family
            case parameterSize = "parameter_size"
        }
    }

    var displayName: String { name }
    var subtitle: String? {
        [details?.family, details?.parameterSize].compactMap { $0 }.joined(separator: " · ")
    }
}

struct OllamaTagsResponse: Codable {
    var models: [OllamaModel]
}

// MARK: - Chat (/api/chat)

/// A message in the Ollama chat format.
struct OllamaChatMessage: Codable {
    var role: String
    var content: String
    /// Base64-encoded images (raw, no `data:` prefix) for vision-capable models.
    var images: [String]?
    var toolCalls: [OllamaToolCall]?
    var toolName: String?

    enum CodingKeys: String, CodingKey {
        case role, content, images
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
    }

    init(
        role: String,
        content: String,
        images: [String]? = nil,
        toolCalls: [OllamaToolCall]? = nil,
        toolName: String? = nil
    ) {
        self.role = role
        self.content = content
        self.images = images
        self.toolCalls = toolCalls
        self.toolName = toolName
    }
}

// MARK: - Web research (/api/web_search, /api/web_fetch)

struct OllamaWebSearchRequest: Codable {
    var query: String
    var maxResults: Int?

    enum CodingKeys: String, CodingKey {
        case query
        case maxResults = "max_results"
    }
}

struct OllamaWebSearchResponse: Codable {
    struct Result: Codable {
        var title: String?
        var url: String?
        var content: String?
    }
    var results: [Result]?
}

struct OllamaWebFetchRequest: Codable {
    var url: String
}

struct OllamaWebFetchResponse: Codable {
    var title: String?
    var content: String?
    var links: [String]?
}

// MARK: - Model capabilities (/api/show)

struct OllamaShowRequest: Codable {
    var model: String
}

struct OllamaShowResponse: Codable {
    /// e.g. ["completion", "tools", "vision"].
    var capabilities: [String]?
}

/// A tool definition sent to the model.
struct OllamaTool: Codable {
    var type: String = "function"
    var function: Function

    struct Function: Codable {
        var name: String
        var description: String
        var parameters: JSONValue
    }
}

/// A tool call the model asks the client to run.
struct OllamaToolCall: Codable {
    var function: Function

    struct Function: Codable {
        var name: String
        var arguments: JSONValue
    }
}

struct OllamaChatRequest: Codable {
    var model: String
    var messages: [OllamaChatMessage]
    var tools: [OllamaTool]?
    var stream: Bool
    var options: Options?

    struct Options: Codable {
        var temperature: Double?
    }
}

/// One streamed NDJSON line from `/api/chat`.
struct OllamaChatStreamLine: Codable {
    var message: Delta?
    var done: Bool?
    var doneReason: String?
    /// Ollama reports mid-stream failures as `{"error": "..."}` lines.
    var error: String?

    enum CodingKeys: String, CodingKey {
        case message, done, error
        case doneReason = "done_reason"
    }

    struct Delta: Codable {
        var role: String?
        var content: String?
        var thinking: String?
        var toolCalls: [OllamaToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content, thinking
            case toolCalls = "tool_calls"
        }
    }
}

/// What `streamChat` emits to callers.
enum OllamaChatChunk {
    case delta(String)                 // incremental assistant text
    case thinking(String)              // incremental reasoning trace
    case toolCalls([OllamaToolCall])   // model requested tools
    case done(reason: String?)         // stream finished
}
