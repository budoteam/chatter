import Foundation
import SwiftData

/// One scheduled reminder — a note the model set via the built-in
/// `reminders__*` tools. Fires as a local system notification at `dueDate`
/// (scheduled per device by `ReminderScheduler`, synced via CloudKit like the
/// other models, so it fires on every signed-in device).
///
/// A reminder with a non-empty `actionPrompt` additionally runs that prompt
/// as an agent turn once the app is opened after `dueDate` (notification tap
/// or plain launch) — reliable on every platform, unlike exact-time
/// background execution, which iOS does not offer.
@Model
final class ReminderEntry {
    var id: UUID = UUID()
    /// Owning agent, referenced by ID (same convention as `MemoryEntry.agentID`
    /// — no relationship, so CloudKit sync stays trivial and dangling refs are
    /// harmless). Nil for reminders created without an agent context.
    var agentID: UUID? = nil
    /// What the user should be reminded of; also the notification body.
    var content: String = ""
    var dueDate: Date = Date()
    /// Optional prompt to run as an agent turn once the app opens after
    /// `dueDate`. Empty = pure notification reminder.
    var actionPrompt: String = ""
    var isCompleted: Bool = false
    /// Set when the action turn was started (before it runs, so a crash or a
    /// second device can never double-run it). Nil = action still pending.
    var actionCompletedAt: Date? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(agentID: UUID? = nil, content: String = "", dueDate: Date = Date(), actionPrompt: String = "") {
        self.id = UUID()
        self.agentID = agentID
        self.content = content
        self.dueDate = dueDate
        self.actionPrompt = actionPrompt
        self.isCompleted = false
        self.actionCompletedAt = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// The first 8 hex chars of the UUID — how the model addresses this entry
    /// in tool calls (shown as `[ab12cd34]` in the system prompt).
    var shortID: String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}
