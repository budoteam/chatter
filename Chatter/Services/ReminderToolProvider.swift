import Foundation
import SwiftData

/// The agent's reminder capability: the model schedules, lists, completes and
/// deletes reminders via four built-in tools — `reminders__create`,
/// `reminders__list`, `reminders__complete`, `reminders__delete`. Open
/// reminders are injected into the system prompt every turn (like memory),
/// so the model can bring up overdue ones.
///
/// Firing is handled by `ReminderScheduler` (local notifications, per device,
/// CloudKit-synced entries). A reminder may carry an `action` prompt that
/// runs as an agent turn once the app opens after the due date — see
/// `AppEnvironment.runDueReminderActions`.
///
/// The `reminders__` prefix rides the same `server__tool` naming convention
/// MCP tools use, so names stay distinct for the model. Entries are addressed
/// by the first 8 hex chars of their UUID, shown as `[ab12cd34]`.
@MainActor
final class ReminderToolProvider {
    nonisolated static let createToolName = "reminders__create"
    nonisolated static let listToolName = "reminders__list"
    nonisolated static let completeToolName = "reminders__complete"
    nonisolated static let deleteToolName = "reminders__delete"

    /// Keeps the injected reminder listing from crowding out the conversation.
    private nonisolated static let promptCharacterLimit = 2_000
    /// A reminder is one short note, not an essay.
    private nonisolated static let contentCharacterLimit = 2_000

    /// Notification hooks, injectable for tests (UNUserNotificationCenter is
    /// not meaningful there). The defaults talk to `ReminderScheduler`.
    var scheduleNotification: (ReminderEntry) -> Void = { entry in
        Task { await ReminderScheduler.schedule(entry) }
    }
    var cancelNotification: (UUID) -> Void = { ReminderScheduler.cancel($0) }

    enum ToolError: LocalizedError {
        case unknownTool(String)
        case missingArgument(String)
        case emptyContent
        case contentTooLong(Int)
        case invalidDate(String)
        case pastDate(String)
        case entryNotFound(String)
        case ambiguousID(String)

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name):
                return "Unknown reminders tool “\(name)”."
            case .missingArgument(let name):
                return "Missing required argument “\(name)”."
            case .emptyContent:
                return "Reminder content must not be empty."
            case .contentTooLong(let count):
                return "Reminder content is \(count) characters — keep reminders short (max \(contentCharacterLimit))."
            case .invalidDate(let value):
                return "Could not parse due date “\(value)” — use ISO 8601 with timezone, e.g. \"2026-08-10T09:00:00+02:00\"."
            case .pastDate(let value):
                return "Due date \(value) is in the past — schedule reminders in the future."
            case .entryNotFound(let id):
                return "No reminder with id “\(id)” — open reminders are listed in your system prompt."
            case .ambiguousID(let id):
                return "Several reminders match id “\(id)” — use more characters of the id."
            }
        }
    }

    // MARK: - System prompt

    /// The current local time (so the model can resolve "in 20 minutes" /
    /// "tomorrow morning") plus the open reminders and the standing
    /// instructions. Non-nil whenever there is anything to say — which is
    /// always, since the time anchor is what makes `create` usable.
    func systemPromptSection(agentID: UUID?, context: ModelContext) -> String {
        let open = entries(for: agentID, context: context)
            .filter { !$0.isCompleted }
            .sorted { $0.dueDate < $1.dueDate }

        var text = """
        # Reminders
        You can schedule reminders for the user. They fire as system notifications \
        at their due time, even when the app is closed. Only create a reminder \
        when the user explicitly asks for one. Current local time: \
        \(Self.promptDateFormatter.string(from: Date())) — pass `due` as ISO 8601 \
        with timezone offset.
        """

        if open.isEmpty {
            text += "\nNo open reminders."
        } else {
            text += "\nOpen reminders:"
            let now = Date()
            for entry in open {
                var line = "\n- [\(entry.shortID)] \(entry.content) (due: \(Self.dueFormatter.string(from: entry.dueDate)))"
                if entry.dueDate <= now { line += " — OVERDUE, mention it briefly" }
                if !entry.actionPrompt.isEmpty && entry.actionCompletedAt == nil {
                    line += " [runs an action when the app opens after the due time]"
                }
                if text.count + line.count > Self.promptCharacterLimit {
                    text += "\n(… listing truncated — too many open reminders.)"
                    break
                }
                text += line
            }
        }
        return text
    }

    // MARK: - Tool definitions

    func tools() -> [OllamaTool] {
        [
            OllamaTool(function: .init(
                name: Self.createToolName,
                description: "Schedule a reminder for the user. It fires as a system notification at the due time. Only use when the user explicitly asks to be reminded.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("What to remind the user of, e.g. \"Call the dentist\"."),
                        ]),
                        "due": .object([
                            "type": .string("string"),
                            "description": .string("Due date as ISO 8601 with timezone offset, e.g. \"2026-08-10T09:00:00+02:00\". Resolve relative times (\"in 20 minutes\") against the current local time in your system prompt."),
                        ]),
                        "action": .object([
                            "type": .string("string"),
                            "description": .string("Optional: a prompt to run yourself as a follow-up task when the app opens after the due time, e.g. \"Summarize today's top AI news\". Omit for a plain reminder."),
                        ]),
                    ]),
                    "required": .array([.string("content"), .string("due")]),
                ])
            )),
            OllamaTool(function: .init(
                name: Self.listToolName,
                description: "List your open reminders with their ids and due dates.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            )),
            OllamaTool(function: .init(
                name: Self.completeToolName,
                description: "Mark a reminder as done — e.g. when the user confirms they took care of it.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("The reminder id from the system-prompt listing, e.g. \"ab12cd34\"."),
                        ]),
                    ]),
                    "required": .array([.string("id")]),
                ])
            )),
            OllamaTool(function: .init(
                name: Self.deleteToolName,
                description: "Delete a reminder that is obsolete or that the user asked you to cancel.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("The reminder id from the system-prompt listing, e.g. \"ab12cd34\"."),
                        ]),
                    ]),
                    "required": .array([.string("id")]),
                ])
            )),
        ]
    }

    // MARK: - Dispatch

    /// ChatEngine routes here only for the exact tool names `tools()` offered,
    /// so MCP tools that happen to share the "reminders__" prefix are never
    /// hijacked.
    func call(
        namespacedName: String,
        argumentsJSON: String,
        agentID: UUID?,
        context: ModelContext
    ) throws -> String {
        let args = JSONValue.parse(argumentsJSON).stringArguments

        switch namespacedName {
        case Self.createToolName:
            let content = (args["content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard args["content"] != nil else { throw ToolError.missingArgument("content") }
            guard !content.isEmpty else { throw ToolError.emptyContent }
            guard content.count <= Self.contentCharacterLimit else {
                throw ToolError.contentTooLong(content.count)
            }
            guard let dueRaw = args["due"], !dueRaw.isEmpty else {
                throw ToolError.missingArgument("due")
            }
            guard let due = Self.parseDate(dueRaw) else { throw ToolError.invalidDate(dueRaw) }
            guard due > Date() else { throw ToolError.pastDate(dueRaw) }
            let action = (args["action"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard action.count <= Self.contentCharacterLimit else {
                throw ToolError.contentTooLong(action.count)
            }

            let entry = ReminderEntry(agentID: agentID, content: content, dueDate: due, actionPrompt: action)
            context.insert(entry)
            context.saveOrLog()
            scheduleNotification(entry)
            return "Scheduled reminder [\(entry.shortID)] for \(Self.dueFormatter.string(from: due))."

        case Self.listToolName:
            let open = entries(for: agentID, context: context)
                .filter { !$0.isCompleted }
                .sorted { $0.dueDate < $1.dueDate }
            guard !open.isEmpty else { return "No open reminders." }
            return open.map {
                "- [\($0.shortID)] \($0.content) (due: \(Self.dueFormatter.string(from: $0.dueDate)))"
            }.joined(separator: "\n")

        case Self.completeToolName:
            let entry = try entry(from: args, agentID: agentID, context: context)
            entry.isCompleted = true
            entry.updatedAt = Date()
            context.saveOrLog()
            cancelNotification(entry.id)
            return "Completed reminder [\(entry.shortID)]."

        case Self.deleteToolName:
            let entry = try entry(from: args, agentID: agentID, context: context)
            let shortID = entry.shortID
            context.delete(entry)
            context.saveOrLog()
            cancelNotification(entry.id)
            return "Deleted reminder [\(shortID)]."

        default:
            throw ToolError.unknownTool(namespacedName)
        }
    }

    // MARK: - Helpers

    /// Reads and validates the shared `id` argument for complete/delete.
    private func entry(
        from args: [String: String],
        agentID: UUID?,
        context: ModelContext
    ) throws -> ReminderEntry {
        guard let id = args["id"], !id.isEmpty else { throw ToolError.missingArgument("id") }
        let needle = id.lowercased()
        let matches = entries(for: agentID, context: context)
            .filter { $0.shortID.hasPrefix(needle) }
        guard let match = matches.first else { throw ToolError.entryNotFound(id) }
        guard matches.count == 1 else { throw ToolError.ambiguousID(id) }
        return match
    }

    /// This agent's entries, newest first. Scoped at the database instead of
    /// fetching every agent's entries and filtering in memory.
    private func entries(for agentID: UUID?, context: ModelContext) -> [ReminderEntry] {
        let descriptor = FetchDescriptor<ReminderEntry>(
            predicate: #Predicate { $0.agentID == agentID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// ISO 8601 with timezone; also accepts fractional seconds.
    static func parseDate(_ raw: String) -> Date? {
        if let date = Self.isoFormatter.date(from: raw) { return date }
        return Self.isoFractionalFormatter.date(from: raw)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dueFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    /// Date, time and timezone — the anchor for the model's relative dates.
    private static let promptDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss (z)"
        return formatter
    }()
}
