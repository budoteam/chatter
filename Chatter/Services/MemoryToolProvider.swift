import Foundation
import SwiftData

/// The agent's self-managed persistent memory: the full memory is injected
/// into the system prompt every turn (no read tool needed), and the model
/// maintains it via three built-in write tools — `memory__save`,
/// `memory__update`, `memory__delete`.
///
/// The `memory__` prefix rides the same `server__tool` naming convention MCP
/// tools use, so names stay distinct for the model. Entries are addressed by
/// the first 8 hex chars of their UUID, shown as `[ab12cd34]` in the prompt.
@MainActor
final class MemoryToolProvider {
    nonisolated static let saveToolName = "memory__save"
    nonisolated static let updateToolName = "memory__update"
    nonisolated static let deleteToolName = "memory__delete"

    /// Keeps the injected memory from crowding out the conversation. Beyond
    /// this budget, older entries are hidden and the model is told to
    /// consolidate — the self-pruning loop.
    private nonisolated static let promptCharacterLimit = 4_000
    /// One memory should be a short, self-contained fact — not an essay.
    private nonisolated static let entryCharacterLimit = 2_000

    enum ToolError: LocalizedError {
        case unknownTool(String)
        case missingArgument(String)
        case emptyContent
        case contentTooLong(Int)
        case entryNotFound(String)
        case ambiguousID(String)

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name):
                return "Unknown memory tool “\(name)”."
            case .missingArgument(let name):
                return "Missing required argument “\(name)”."
            case .emptyContent:
                return "Memory content must not be empty."
            case .contentTooLong(let count):
                return "Memory content is \(count) characters — keep memories short and factual (max \(entryCharacterLimit))."
            case .entryNotFound(let id):
                return "No memory with id “\(id)” — current ids are listed in your system prompt."
            case .ambiguousID(let id):
                return "Several memories match id “\(id)” — use more characters of the id."
            }
        }
    }

    // MARK: - System prompt

    /// The full memory listing plus the standing instructions that make the
    /// model use the tools proactively. Non-nil whenever memory is enabled —
    /// even when empty, since the instructions are what bootstrap saving.
    func systemPromptSection(agentID: UUID?, context: ModelContext) -> String {
        let entries = entries(for: agentID, context: context)

        var text = "# Memory\nYou have a persistent memory for this agent."
        if entries.isEmpty {
            text += " It is currently empty."
        } else {
            text += " It currently contains:\n"
            // Newest first; hide the tail once over budget so a bloated
            // memory degrades gracefully instead of flooding the prompt.
            var shown = 0
            var listing = ""
            for entry in entries {
                let line = "\n- [\(entry.shortID)] \(entry.content) (\(Self.dateFormatter.string(from: entry.updatedAt)))"
                if text.count + listing.count + line.count > Self.promptCharacterLimit { break }
                listing += line
                shown += 1
            }
            text += listing
            let hidden = entries.count - shown
            if hidden > 0 {
                text += "\n(\(hidden) older memories not shown — memory is over budget; consolidate with \(Self.updateToolName) / \(Self.deleteToolName).)"
            }
        }
        text += """
        \n
        Manage it yourself, proactively and without being asked:
        - When you learn something durable — the user's name, preferences, \
        corrections, decisions, ongoing projects, recurring context — save it \
        with \(Self.saveToolName) (one short, self-contained fact per entry).
        - When a memory becomes outdated, fix it with \(Self.updateToolName); \
        when obsolete, remove it with \(Self.deleteToolName). Reference \
        entries by their id.
        - Do NOT save trivia, transient task details, or anything the user \
        asks you to forget.
        - Memory space is limited; prefer updating and consolidating over \
        accumulating.
        Never mention this memory system unless the user asks about it.
        """
        return text
    }

    // MARK: - Tool definitions

    func tools() -> [OllamaTool] {
        [
            OllamaTool(function: .init(
                name: Self.saveToolName,
                description: "Save one new memory: a short, self-contained, durable fact about the user or ongoing context. Saved memories appear in your system prompt in future turns.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("The fact to remember, e.g. \"User's name is Fabian; prefers concise German answers.\""),
                        ]),
                    ]),
                    "required": .array([.string("content")]),
                ])
            )),
            OllamaTool(function: .init(
                name: Self.updateToolName,
                description: "Replace the content of an existing memory. Use it to fix outdated facts or consolidate several memories into one.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("The memory id from the system-prompt listing, e.g. \"ab12cd34\"."),
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("The new content that replaces the old one."),
                        ]),
                    ]),
                    "required": .array([.string("id"), .string("content")]),
                ])
            )),
            OllamaTool(function: .init(
                name: Self.deleteToolName,
                description: "Delete a memory that is obsolete or that the user asked you to forget.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("The memory id from the system-prompt listing, e.g. \"ab12cd34\"."),
                        ]),
                    ]),
                    "required": .array([.string("id")]),
                ])
            )),
        ]
    }

    // MARK: - Dispatch

    /// ChatEngine routes here only for the exact tool names `tools()` offered,
    /// so MCP tools that happen to share the "memory__" prefix are never
    /// hijacked.
    func call(
        namespacedName: String,
        argumentsJSON: String,
        agentID: UUID?,
        context: ModelContext
    ) throws -> String {
        let args = arguments(from: argumentsJSON)

        switch namespacedName {
        case Self.saveToolName:
            let content = (args["content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard args["content"] != nil else { throw ToolError.missingArgument("content") }
            guard !content.isEmpty else { throw ToolError.emptyContent }
            guard content.count <= Self.entryCharacterLimit else {
                throw ToolError.contentTooLong(content.count)
            }
            let entry = MemoryEntry(agentID: agentID, content: content)
            context.insert(entry)
            try? context.save()
            return "Saved memory [\(entry.shortID)]."

        case Self.updateToolName:
            guard let id = args["id"], !id.isEmpty else { throw ToolError.missingArgument("id") }
            let content = (args["content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard args["content"] != nil else { throw ToolError.missingArgument("content") }
            guard !content.isEmpty else { throw ToolError.emptyContent }
            guard content.count <= Self.entryCharacterLimit else {
                throw ToolError.contentTooLong(content.count)
            }
            let entry = try entry(matching: id, agentID: agentID, context: context)
            entry.content = content
            entry.updatedAt = Date()
            try? context.save()
            return "Updated memory [\(entry.shortID)]."

        case Self.deleteToolName:
            guard let id = args["id"], !id.isEmpty else { throw ToolError.missingArgument("id") }
            let entry = try entry(matching: id, agentID: agentID, context: context)
            let shortID = entry.shortID
            context.delete(entry)
            try? context.save()
            return "Deleted memory [\(shortID)]."

        default:
            throw ToolError.unknownTool(namespacedName)
        }
    }

    // MARK: - Helpers

    /// This agent's entries, newest first. Fetch-all-and-filter matches the
    /// codebase style; memory counts are small by design.
    private func entries(for agentID: UUID?, context: ModelContext) -> [MemoryEntry] {
        let all = (try? context.fetch(FetchDescriptor<MemoryEntry>())) ?? []
        return all
            .filter { $0.agentID == agentID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Case-insensitive prefix match against this agent's entries.
    private func entry(
        matching id: String,
        agentID: UUID?,
        context: ModelContext
    ) throws -> MemoryEntry {
        let needle = id.lowercased()
        let matches = entries(for: agentID, context: context)
            .filter { $0.shortID.hasPrefix(needle) }
        guard let match = matches.first else { throw ToolError.entryNotFound(id) }
        guard matches.count == 1 else { throw ToolError.ambiguousID(id) }
        return match
    }

    private func arguments(from json: String) -> [String: String] {
        guard case .object(let object) = JSONValue.parse(json) else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            if case .string(let s) = value { result[key] = s }
        }
        return result
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()
}
