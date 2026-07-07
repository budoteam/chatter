import Foundation
import SwiftData

/// One persistent memory of an agent — a short, self-contained fact the model
/// saved about the user or ongoing context. The full memory is injected into
/// the system prompt each turn; the model maintains it via the built-in
/// `memory__save` / `memory__update` / `memory__delete` tools.
@Model
final class MemoryEntry {
    var id: UUID = UUID()
    /// Owning agent, referenced by ID (same convention as `Agent.mcpServerIDs`
    /// — no relationship, so CloudKit sync stays trivial and dangling refs are
    /// harmless).
    var agentID: UUID? = nil
    var content: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(agentID: UUID? = nil, content: String = "") {
        self.id = UUID()
        self.agentID = agentID
        self.content = content
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// The first 8 hex chars of the UUID — how the model addresses this entry
    /// in tool calls (shown as `[ab12cd34]` in the system prompt).
    var shortID: String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}
