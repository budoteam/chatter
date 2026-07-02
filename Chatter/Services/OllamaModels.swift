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
    var toolCalls: [OllamaToolCall]?
    var toolName: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
    }

    init(role: String, content: String, toolCalls: [OllamaToolCall]? = nil, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
    }
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
        var toolCalls: [OllamaToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
        }
    }
}

/// What `streamChat` emits to callers.
enum OllamaChatChunk {
    case delta(String)                 // incremental assistant text
    case toolCalls([OllamaToolCall])   // model requested tools
    case done(reason: String?)         // stream finished
}
