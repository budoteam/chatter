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
    /// For user turns with image attachments: JSON-encoded `[ImageAttachment]`.
    var attachmentsJSON: String?
    /// For `tool` role messages: which tool produced this result.
    var toolName: String?
    /// Reasoning trace from thinking models (shown dimmed in the UI).
    var thinking: String?
    /// Textual description of the image attachments, produced once by the global
    /// vision fallback model when the chat model itself can't process images
    /// (empty = none). Sent to the chat model instead of the images; not shown
    /// in the UI.
    var imageNote: String = ""
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

    var imageAttachments: [ImageAttachment] {
        get {
            guard let json = attachmentsJSON, let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([ImageAttachment].self, from: data)) ?? []
        }
        set {
            guard !newValue.isEmpty,
                  let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else {
                attachmentsJSON = nil
                return
            }
            attachmentsJSON = json
        }
    }
}

/// An image attached to a user message, stored as downscaled Base64 JPEG.
struct ImageAttachment: Codable, Identifiable, Hashable {
    /// Total Base64 size budget for all attachments of one message. CloudKit
    /// rejects records whose non-asset fields exceed ~1 MB, and an oversized
    /// message record would stall sync of the whole chat — the composer
    /// refuses images that would push a message past this budget.
    static let maxBase64BytesPerMessage = 700_000

    var id: UUID = UUID()
    /// Raw Base64 JPEG (no `data:` prefix), ready for Ollama's `images` array.
    var base64: String
}

/// A tool invocation requested by the model.
struct ToolCall: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    /// Namespaced name, e.g. "filesystem.read_file".
    var name: String
    /// JSON-encoded argument object (kept as a string for portability).
    var argumentsJSON: String
}
