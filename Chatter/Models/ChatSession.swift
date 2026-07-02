import Foundation
import SwiftData

/// One conversation thread. Owns its messages and references the agent that
/// drives it.
@Model
final class ChatSession {
    var id: UUID = UUID()
    var title: String = "New Chat"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Snapshot of the model id used, so the session is self-describing even if
    /// the agent later changes.
    var modelId: String = ""

    var agent: Agent?

    @Relationship(deleteRule: .cascade, inverse: \Message.session)
    var messages: [Message]? = []

    init(title: String = "New Chat", agent: Agent? = nil, modelId: String = "") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.agent = agent
        self.modelId = modelId
    }

    /// Messages in stable chronological order.
    var orderedMessages: [Message] {
        (messages ?? []).sorted { $0.orderIndex < $1.orderIndex }
    }

    var nextOrderIndex: Int {
        (messages ?? []).map(\.orderIndex).max().map { $0 + 1 } ?? 0
    }
}
