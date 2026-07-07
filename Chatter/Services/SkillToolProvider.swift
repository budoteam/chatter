import Foundation
import SwiftData

/// Exposes the shared skill pool to the model with progressive disclosure:
/// the system prompt carries only an index (name + summary) of the agent's
/// enabled skills, and `skills__read` loads a body on demand. Agents with
/// authoring enabled can also write skills (`skills__create` /
/// `skills__update`) — created skills are auto-enabled for the author.
///
/// The `skills__` prefix rides the same `server__tool` naming convention MCP
/// tools use, so names stay distinct for the model.
@MainActor
final class SkillToolProvider {
    nonisolated static let readToolName = "skills__read"
    nonisolated static let createToolName = "skills__create"
    nonisolated static let updateToolName = "skills__update"

    /// Keeps the system-prompt skill index from crowding out the conversation.
    private nonisolated static let indexCharacterLimit = 2_000
    /// Keeps a single tool result within a sane share of the context window.
    private nonisolated static let readCharacterLimit = 16_000
    /// A skill is a procedure, not a book.
    private nonisolated static let contentCharacterLimit = 24_000

    enum ToolError: LocalizedError {
        case unknownTool(String)
        case missingArgument(String)
        case skillNotFound(String, available: [String])
        case duplicateName(String)
        case emptyName
        case contentTooLong(Int)
        case nothingToUpdate

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name):
                return "Unknown skills tool “\(name)”."
            case .missingArgument(let name):
                return "Missing required argument “\(name)”."
            case .skillNotFound(let name, let available):
                let list = available.isEmpty
                    ? "You have no skills enabled."
                    : "Available skills: \(available.joined(separator: ", "))."
                return "No skill named “\(name)”. \(list)"
            case .duplicateName(let name):
                return "Skill “\(name)” already exists — use \(updateToolName) to change it, or pick another name."
            case .emptyName:
                return "Skill name must not be empty."
            case .contentTooLong(let count):
                return "Skill content is \(count) characters (max \(contentCharacterLimit)) — keep skills concise."
            case .nothingToUpdate:
                return "Pass at least one of “content” or “summary” to update."
            }
        }
    }

    // MARK: - System prompt

    /// The index of enabled skills plus, when authoring is on, the standing
    /// instruction to persist reusable procedures. Nil only when there is
    /// nothing to say (no resolvable skills and no authoring).
    func systemPromptSection(
        skillIDs: [UUID],
        authoringEnabled: Bool,
        context: ModelContext
    ) -> String? {
        let skills = skills(for: skillIDs, context: context)
        guard !skills.isEmpty || authoringEnabled else { return nil }

        var text = "# Skills"
        if skills.isEmpty {
            text += "\nYou have no skills yet."
        } else {
            text += """
            \nYou have the following skills — stored procedures and \
            instructions you wrote or were given. Before performing a task a \
            skill covers, load it with \(Self.readToolName) and follow it.\n
            """
            for skill in skills {
                let line = "\n- \(skill.name): \(skill.summary)"
                if text.count + line.count > Self.indexCharacterLimit {
                    text += "\n(… index truncated — too many skills enabled.)"
                    break
                }
                text += line
            }
        }
        if authoringEnabled {
            text += """
            \n
            You may also author skills: when the user teaches you a reusable \
            procedure, or you refine one through trial and error, persist it \
            with \(Self.createToolName) (or improve an existing one with \
            \(Self.updateToolName)). Write skills as concise step-by-step \
            markdown. Skills are shared across agents — keep them general, \
            not conversation-specific.
            """
        }
        return text
    }

    // MARK: - Tool definitions

    func tools(
        skillIDs: [UUID],
        authoringEnabled: Bool,
        context: ModelContext
    ) -> [OllamaTool] {
        var tools: [OllamaTool] = []
        // Read is offered with authoring even at zero skills: a skill created
        // mid-turn must be readable in the same turn.
        if authoringEnabled || !skills(for: skillIDs, context: context).isEmpty {
            tools.append(OllamaTool(function: .init(
                name: Self.readToolName,
                description: "Read one of your skills in full. Use the skill names listed in your system prompt.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("The skill name, e.g. \"weekly-report\"."),
                        ]),
                    ]),
                    "required": .array([.string("name")]),
                ])
            )))
        }
        if authoringEnabled {
            tools.append(OllamaTool(function: .init(
                name: Self.createToolName,
                description: "Create a new skill in the shared pool: a reusable step-by-step procedure written as markdown. The skill is enabled for you immediately.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Short slug-style name, e.g. \"weekly-report\". Lowercase letters, digits and hyphens."),
                        ]),
                        "summary": .object([
                            "type": .string("string"),
                            "description": .string("One line describing when to use the skill."),
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("The full skill body: concise step-by-step markdown instructions."),
                        ]),
                    ]),
                    "required": .array([.string("name"), .string("summary"), .string("content")]),
                ])
            )))
            tools.append(OllamaTool(function: .init(
                name: Self.updateToolName,
                description: "Update one of your enabled skills — replace its content and/or summary.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("The name of the skill to update."),
                        ]),
                        "summary": .object([
                            "type": .string("string"),
                            "description": .string("New one-line summary (optional)."),
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("New markdown body (optional)."),
                        ]),
                    ]),
                    "required": .array([.string("name")]),
                ])
            )))
        }
        return tools
    }

    // MARK: - Dispatch

    /// ChatEngine routes here only for the exact tool names `tools(…)`
    /// offered, so MCP tools that happen to share the "skills__" prefix are
    /// never hijacked. Takes the `Agent` because create mutates
    /// `agent.skillIDs` (auto-enable for the author).
    func call(
        namespacedName: String,
        argumentsJSON: String,
        agent: Agent,
        context: ModelContext
    ) throws -> String {
        let args = arguments(from: argumentsJSON)

        switch namespacedName {
        case Self.readToolName:
            guard let name = args["name"], !name.isEmpty else {
                throw ToolError.missingArgument("name")
            }
            let enabled = skills(for: agent.skillIDs, context: context)
            guard let skill = match(name: name, in: enabled) else {
                throw ToolError.skillNotFound(name, available: enabled.map(\.name))
            }
            var text = "Skill: \(skill.name)\n\(skill.summary)\n\n\(skill.content)"
            if text.count > Self.readCharacterLimit {
                let overflow = text.count - Self.readCharacterLimit
                text = String(text.prefix(Self.readCharacterLimit))
                    + "\n… [truncated \(overflow) characters]"
            }
            return text

        case Self.createToolName:
            guard let rawName = args["name"], !rawName.isEmpty else {
                throw ToolError.missingArgument("name")
            }
            guard let summary = args["summary"], !summary.isEmpty else {
                throw ToolError.missingArgument("summary")
            }
            guard let content = args["content"], !content.isEmpty else {
                throw ToolError.missingArgument("content")
            }
            guard content.count <= Self.contentCharacterLimit else {
                throw ToolError.contentTooLong(content.count)
            }
            let name = Self.slugify(rawName)
            guard !name.isEmpty else { throw ToolError.emptyName }
            // Uniqueness is checked against the whole pool, not just this
            // agent's skills — names are the global address space.
            let all = (try? context.fetch(FetchDescriptor<Skill>())) ?? []
            guard !all.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw ToolError.duplicateName(name)
            }
            let skill = Skill(name: name, summary: summary, content: content)
            context.insert(skill)
            agent.skillIDs.append(skill.id)
            try? context.save()
            return "Created skill “\(name)” and enabled it for you."

        case Self.updateToolName:
            guard let name = args["name"], !name.isEmpty else {
                throw ToolError.missingArgument("name")
            }
            let summary = args["summary"]
            let content = args["content"]
            guard summary != nil || content != nil else { throw ToolError.nothingToUpdate }
            if let content, content.count > Self.contentCharacterLimit {
                throw ToolError.contentTooLong(content.count)
            }
            // Only the agent's own enabled skills — no silent rewrites of
            // skills it hasn't opted into.
            let enabled = skills(for: agent.skillIDs, context: context)
            guard let skill = match(name: name, in: enabled) else {
                throw ToolError.skillNotFound(name, available: enabled.map(\.name))
            }
            if let summary, !summary.isEmpty { skill.summary = summary }
            if let content, !content.isEmpty { skill.content = content }
            skill.updatedAt = Date()
            try? context.save()
            return "Updated skill “\(skill.name)”."

        default:
            throw ToolError.unknownTool(namespacedName)
        }
    }

    // MARK: - Helpers

    /// Resolves skill IDs, silently skipping dangling references (a skill
    /// deleted on another device may still be listed on an agent).
    private func skills(for ids: [UUID], context: ModelContext) -> [Skill] {
        guard !ids.isEmpty else { return [] }
        let all = (try? context.fetch(FetchDescriptor<Skill>())) ?? []
        let wanted = Set(ids)
        return all.filter { wanted.contains($0.id) }.sorted { $0.name < $1.name }
    }

    private func match(name: String, in skills: [Skill]) -> Skill? {
        skills.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// "Weekly Report!" → "weekly-report". Keeps only [a-z0-9-_].
    static func slugify(_ raw: String) -> String {
        let lowered = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        return String(lowered.unicodeScalars.filter { allowed.contains($0) })
    }

    private func arguments(from json: String) -> [String: String] {
        guard case .object(let object) = JSONValue.parse(json) else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            if case .string(let s) = value { result[key] = s }
        }
        return result
    }
}
