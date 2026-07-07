import Foundation
import SwiftData

/// A reusable procedure/instruction in the app-wide skill pool. Agents opt in
/// via `Agent.skillIDs`; enabled skills are listed (name + summary) in the
/// system prompt and loaded in full on demand via `skills__read`. Agents with
/// authoring enabled can write skills themselves (`skills__create` /
/// `skills__update`).
@Model
final class Skill {
    var id: UUID = UUID()
    /// Slug the model addresses the skill by, e.g. "weekly-report".
    /// Unique by convention — the tool provider rejects duplicates
    /// (`@Attribute(.unique)` is not CloudKit-compatible).
    var name: String = ""
    /// One-liner shown in the system-prompt skill index.
    var summary: String = ""
    /// Markdown body, loaded only when the model calls skills__read.
    var content: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(name: String = "", summary: String = "", content: String = "") {
        self.id = UUID()
        self.name = name
        self.summary = summary
        self.content = content
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
