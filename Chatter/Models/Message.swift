import Foundation
import SwiftData

enum MessageRole: String, Codable, CaseIterable {
    case system
    case user
    case assistant
    case tool
}

/// A single chat message. Tool calls/results are stored as encoded JSON to keep
/// the CloudKit schema flat.
@Model
final class Message {
    var id: UUID = UUID()
    var roleRaw: String = MessageRole.user.rawValue
    var content: String = ""
    var orderIndex: Int = 0
    var createdAt: Date = Date()

    /// For assistant turns that requested tools: JSON-encoded `[ToolCall]`.
    var toolCallsJSON: String?
    /// For `tool` role messages: which tool produced this result.
    var toolName: String?
    /// Reasoning trace from thinking models (shown collapsed in the UI).
    var thinking: String?
    /// True while tokens are still streaming into `content`.
    var isStreaming: Bool = false

    var session: ChatSession?

    init(
        role: MessageRole,
        content: String = "",
        orderIndex: Int = 0,
        toolName: String? = nil,
        isStreaming: Bool = false
    ) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.content = content
        self.orderIndex = orderIndex
        self.createdAt = Date()
        self.toolName = toolName
        self.isStreaming = isStreaming
    }

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    var toolCalls: [ToolCall] {
        get {
            guard let json = toolCallsJSON, let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([ToolCall].self, from: data)) ?? []
        }
        set {
            guard !newValue.isEmpty,
                  let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else {
                toolCallsJSON = nil
                return
            }
            toolCallsJSON = json
        }
    }
}

/// A tool invocation requested by the model.
struct ToolCall: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    /// Namespaced name, e.g. "filesystem.read_file".
    var name: String
    /// JSON-encoded argument object (kept as a string for portability).
    var argumentsJSON: String

    var arguments: [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }
}
