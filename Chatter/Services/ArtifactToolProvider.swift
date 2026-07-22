import Foundation
import SwiftData

/// Built-in file tool: the model creates CSV / Markdown / code artifacts that
/// render as a clickable pill in the chat and open in the side panel (macOS)
/// or a sheet (iOS). Artifacts are SwiftData rows on the session, so they
/// sync via CloudKit like messages do.
@MainActor
final class ArtifactToolProvider {
    static let createToolName = "artifact__create"

    /// Keeps the inline `content` string well under CloudKit's ~1 MB record
    /// limit; an oversized record would stall sync of the whole session.
    nonisolated static let maxContentBytes = 900_000

    enum ToolError: LocalizedError {
        case unknownTool(String)
        case missingArgument(String)
        case artifactTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name): return "Unknown artifact tool “\(name)”."
            case .missingArgument(let name): return "Missing required argument “\(name)”."
            case .artifactTooLarge(let bytes):
                return "Artifact content is \(bytes) bytes — the limit is \(ArtifactToolProvider.maxContentBytes). Split it into smaller files."
            }
        }
    }

    // MARK: - System prompt

    static let systemPromptSection = """
        You can create file artifacts with the \(createToolName) tool. Use it \
        whenever you would otherwise dump a CSV, a markdown document, or more \
        than ~30 lines of code inline: the file becomes clickable in the chat \
        and opens rendered (table, markdown preview, code) in the side panel. \
        After creating an artifact, answer with a short summary only — do not \
        repeat the file contents in your reply.
        """

    // MARK: - Tool definitions

    func tools() -> [OllamaTool] {
        [OllamaTool(function: .init(
            name: Self.createToolName,
            description: "Create or replace a file artifact attached to this chat. Use this whenever you would otherwise dump a CSV, a markdown document, or more than ~30 lines of code inline. The file becomes clickable in the chat and opens in the side panel. Pass replace=false to keep multiple versions under the same name.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("File name including extension, e.g. \"sales-q3.csv\"."),
                    ]),
                    "kind": .object([
                        "type": .string("string"),
                        "enum": .array(ArtifactKind.allCases.map { .string($0.rawValue) }),
                        "description": .string("How the file renders in the panel. Defaults to \"code\"."),
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("The full file contents."),
                    ]),
                    "replace": .object([
                        "type": .string("boolean"),
                        "description": .string("Replace an existing artifact with the same name (default true). Pass false to keep multiple versions."),
                    ]),
                ]),
                "required": .array([.string("name"), .string("content")]),
            ])
        ))]
    }

    // MARK: - Dispatch

    /// Creates or replaces the artifact named in the arguments. Replace is
    /// keyed on `(session, name)`; `replace=false` always inserts a new row
    /// so several versions can coexist under one name.
    @discardableResult
    func call(
        name: String,
        argumentsJSON: String,
        session: ChatSession,
        sourceToolCallID: String?,
        context: ModelContext
    ) throws -> String {
        guard name == Self.createToolName else { throw ToolError.unknownTool(name) }
        let parsed = JSONValue.parse(argumentsJSON)
        let args = parsed.stringArguments
        guard let artifactName = args["name"], !artifactName.isEmpty else {
            throw ToolError.missingArgument("name")
        }
        guard let content = args["content"], !content.isEmpty else {
            throw ToolError.missingArgument("content")
        }
        let byteCount = content.utf8.count
        guard byteCount <= Self.maxContentBytes else {
            throw ToolError.artifactTooLarge(byteCount)
        }
        // `stringArguments` drops non-string values, so the replace flag is
        // read from the parsed object directly.
        var replace = true
        if case .object(let object) = parsed, case .bool(let flag) = object["replace"] {
            replace = flag
        }
        let kind = args["kind"].flatMap { ArtifactKind(rawValue: $0) } ?? .code

        let sessionID = session.id
        let existingDescriptor = FetchDescriptor<Artifact>(
            predicate: #Predicate {
                $0.session?.id == sessionID && $0.name == artifactName
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let existing = (try? context.fetch(existingDescriptor)) ?? []

        let artifact: Artifact
        if replace, let current = existing.first {
            current.kind = kind
            current.content = content
            current.createdAt = Date()
            current.sourceToolCallID = sourceToolCallID
            artifact = current
        } else {
            let created = Artifact(
                name: artifactName, kind: kind, content: content,
                sourceToolCallID: sourceToolCallID
            )
            created.session = session
            context.insert(created)
            artifact = created
        }
        session.updatedAt = .now
        context.saveOrLog()

        let size = String(format: "%.1f KB", Double(byteCount) / 1000)
        // Doubles as the compact confirmation line in the chat UI — the
        // "don't repeat the contents" instruction lives in the system prompt.
        return "Created artifact '\(artifact.name)' (\(artifact.kind.rawValue), \(size)). Visible in the chat and side panel."
    }
}
