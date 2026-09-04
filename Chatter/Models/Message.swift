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
    /// For user turns with PDF attachments: JSON-encoded `[DocumentAttachment]`
    /// (metadata only — the extracted text lives inline in `content`).
    var documentsJSON: String?
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

    var documentAttachments: [DocumentAttachment] {
        get {
            guard let json = documentsJSON, let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([DocumentAttachment].self, from: data)) ?? []
        }
        set {
            guard !newValue.isEmpty,
                  let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else {
                documentsJSON = nil
                return
            }
            documentsJSON = json
        }
    }

    /// The part of `content` the user actually typed. Document text blocks
    /// appended by `ChatEngine` are hidden in the bubble (the attachments
    /// render as chips instead) but stay in `content` so the model — on this
    /// and every synced device — sees them verbatim.
    var typedContent: String {
        guard let range = content.range(of: DocumentPromptFormat.separator) else { return content }
        return String(content[..<range.lowerBound])
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

/// Metadata of a PDF attached to a user message. The extracted text is NOT
/// stored here — it is appended to `Message.content` by `ChatEngine`, so the
/// JSON stays tiny and the text syncs in the field the model reads anyway.
struct DocumentAttachment: Codable, Identifiable, Hashable {
    /// Extracted text per PDF is capped at this many characters (context
    /// window and CloudKit's ~1 MB record budget); the rest is truncated.
    static let maxCharactersPerDocument = 100_000
    /// Total extracted-text budget across all PDFs of one message.
    static let maxCharactersPerMessage = 200_000

    var id: UUID = UUID()
    var fileName: String
    var pageCount: Int
    /// True when the text came from on-device Vision OCR (scanned PDF).
    var usedOCR: Bool = false
    /// True when the extracted text hit `maxCharactersPerDocument`.
    var truncated: Bool = false
}

/// A PDF ready to be sent: attachment metadata plus its extracted text.
/// Exists only until the send composes it into `Message.content`.
struct DocumentDraft: Identifiable, Hashable {
    var attachment: DocumentAttachment
    var text: String
    var id: UUID { attachment.id }
}

/// How attached documents are embedded into the user message the model sees.
/// The format is ours end to end: `ChatEngine` composes it, `typedContent`
/// strips it again for display.
enum DocumentPromptFormat {
    /// Placed before each appended document block; everything from the first
    /// occurrence on is document payload, not typed text.
    static let separator = "\n\n[Document: "

    static func block(for document: DocumentAttachment, text: String) -> String {
        var header = "[Document: \(document.fileName) — \(document.pageCount) "
            + (document.pageCount == 1 ? "page" : "pages")
        if document.usedOCR { header += ", OCR" }
        if document.truncated { header += ", truncated" }
        return header + "]\n" + text
    }

    static func compose(text: String, documents: [DocumentDraft]) -> String {
        documents.reduce(text) { $0 + separator + block(for: $1.attachment, text: $1.text) }
    }
}
