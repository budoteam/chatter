import Foundation

/// A `Codable` representation of arbitrary JSON, used for MCP tool input
/// schemas and for the argument objects the model returns in tool calls.
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    /// Compact JSON string.
    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Parse a JSON string into a value (defaults to empty object on failure).
    static func parse(_ string: String) -> JSONValue {
        guard let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object([:])
        }
        return value
    }
}

extension JSONValue {
    /// String-only view of a tool-call argument object — the shape every
    /// built-in tool provider consumes. Non-string values are dropped.
    var stringArguments: [String: String] {
        guard case .object(let object) = self else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            if case .string(let s) = value { result[key] = s }
        }
        return result
    }
}
