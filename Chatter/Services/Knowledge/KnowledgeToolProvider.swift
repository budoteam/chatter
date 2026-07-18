import Foundation
import SwiftData

/// Exposes the agent's knowledge bundles to the model: a compact overview for
/// the system prompt plus two built-in tools (`knowledge__list`,
/// `knowledge__read`) for progressive disclosure — the model sees what exists
/// cheaply and fetches full concept bodies only on demand.
///
/// The `knowledge__` prefix rides the same `server__tool` naming convention
/// MCP tools use, so names stay distinct for the model.
@MainActor
final class KnowledgeToolProvider {
    static let listToolName = "knowledge__list"
    static let readToolName = "knowledge__read"

    /// Keeps the system-prompt overview from crowding out the conversation.
    private static let overviewCharacterLimit = 3_000
    /// Keeps a single tool result within a sane share of the context window.
    /// Internal so the PDF importer can size concept bodies to fit under it.
    nonisolated static let readCharacterLimit = 16_000

    enum ToolError: LocalizedError {
        case unknownTool(String)
        case missingArgument(String)
        case conceptNotFound(String)

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name): return "Unknown knowledge tool “\(name)”."
            case .missingArgument(let name): return "Missing required argument “\(name)”."
            case .conceptNotFound(let id): return "No concept with id “\(id)”. Use knowledge__list to see what exists."
            }
        }
    }

    // MARK: - System prompt

    /// A compact listing of the agent's bundles (root index contents, or a
    /// generated listing), capped so large knowledge bases don't blow up the
    /// prompt. Every bundle contributes at least its name; oversized indexes
    /// are cut to the remaining budget. Returns nil when the agent has no
    /// (resolvable) bundles.
    func systemPromptSection(bundleIDs: [UUID], context: ModelContext) -> String? {
        let bundles = bundles(for: bundleIDs, context: context)
        guard !bundles.isEmpty else { return nil }

        var text = """
        You have access to a knowledge base. The overview below lists what it \
        contains. Use the \(Self.listToolName) tool to browse or search it and \
        the \(Self.readToolName) tool to read a concept in full before \
        answering questions its contents could inform.
        """
        for bundle in bundles {
            text += "\n\n## Knowledge bundle: \(bundle.name)\n"
            let remaining = Self.overviewCharacterLimit - text.count
            guard remaining > 80 else {
                text += "(Use \(Self.listToolName) to browse this bundle.)"
                continue
            }
            let index = rootIndexText(for: bundle)
            if index.count <= remaining {
                text += index
            } else {
                text += String(index.prefix(remaining))
                    + "\n(… overview truncated — use \(Self.listToolName) for the rest.)"
            }
        }
        return text
    }

    /// The bundle's stored root `index.md`, else a generated listing — the
    /// single fallback rule shared by the prompt overview and knowledge__list.
    private func rootIndexText(for bundle: KnowledgeBundle) -> String {
        (bundle.concept(atPath: "index")?.body
            ?? KnowledgeTransfer.generatedRootIndex(for: bundle))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tool definitions

    func tools(bundleIDs: [UUID], context: ModelContext) -> [OllamaTool] {
        guard !bundles(for: bundleIDs, context: context).isEmpty else { return [] }
        return [
            OllamaTool(function: .init(
                name: Self.listToolName,
                description: "Browse or search the knowledge base. Without arguments, returns the top-level overview. Pass `path` to list concepts under a folder, or `query` to full-text search across all concepts.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Folder path to list, e.g. \"tables\". Omit for the root overview."),
                        ]),
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search text matched against concept ids, titles, types, tags, descriptions, and bodies."),
                        ]),
                    ]),
                ])
            )),
            OllamaTool(function: .init(
                name: Self.readToolName,
                description: "Read one knowledge concept in full (frontmatter and markdown body). Use the concept ids returned by \(Self.listToolName).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "concept_id": .object([
                            "type": .string("string"),
                            "description": .string("The concept id (bundle-relative path without .md), e.g. \"tables/users\"."),
                        ]),
                        "bundle": .object([
                            "type": .string("string"),
                            "description": .string("Bundle name, only needed when the same concept id exists in several bundles."),
                        ]),
                    ]),
                    "required": .array([.string("concept_id")]),
                ])
            )),
        ]
    }

    // MARK: - Dispatch

    /// ChatEngine routes here only for the exact tool names `tools(…)`
    /// offered, so MCP tools that happen to share the "knowledge__" prefix
    /// (a server named "Knowledge") are never hijacked.
    func call(
        namespacedName: String,
        argumentsJSON: String,
        bundleIDs: [UUID],
        context: ModelContext
    ) throws -> String {
        let bundles = bundles(for: bundleIDs, context: context)
        guard !bundles.isEmpty else {
            // Bundles can vanish mid-turn (deleted locally or via sync);
            // never hand the model an empty result with no explanation.
            return "No knowledge bundles are currently available for this agent."
        }
        let args = JSONValue.parse(argumentsJSON).stringArguments

        switch namespacedName {
        case Self.listToolName:
            return list(path: args["path"], query: args["query"], bundles: bundles)
        case Self.readToolName:
            guard let conceptID = args["concept_id"], !conceptID.isEmpty else {
                throw ToolError.missingArgument("concept_id")
            }
            return try read(conceptID: conceptID, bundleName: args["bundle"], bundles: bundles)
        default:
            throw ToolError.unknownTool(namespacedName)
        }
    }

    // MARK: - knowledge__list

    private func list(path: String?, query: String?, bundles: [KnowledgeBundle]) -> String {
        if let query, !query.isEmpty {
            return search(query: query, bundles: bundles)
        }

        if let path, !path.isEmpty {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let matches = bundles.flatMap { bundle in
                bundle.conceptDocuments
                    .filter { $0.path.hasPrefix(prefix) || $0.path == path }
                    .map { entryLine(for: $0, in: bundle, qualify: bundles.count > 1) }
            }
            if matches.isEmpty {
                return "No concepts under “\(path)”. Call \(Self.listToolName) without arguments for the overview."
            }
            return matches.joined(separator: "\n")
        }

        // Root overview: stored root index per bundle, else a generated one.
        return bundles.map { bundle in
            "# Bundle: \(bundle.name)\n" + rootIndexText(for: bundle)
        }
        .joined(separator: "\n\n")
    }

    private func search(query: String, bundles: [KnowledgeBundle]) -> String {
        var strong: [String] = []  // hits in id/title/type/tags/description
        var weak: [String] = []    // body-only hits

        for bundle in bundles {
            for concept in bundle.conceptDocuments {
                let metadata = (
                    [concept.path, concept.title ?? "", concept.typeName, concept.summary ?? ""]
                        + concept.tags
                )
                .joined(separator: " ")
                let line = entryLine(for: concept, in: bundle, qualify: bundles.count > 1)
                // range(of:options:) avoids allocating lowercased copies of
                // every body on each search call.
                if metadata.range(of: query, options: .caseInsensitive) != nil {
                    strong.append(line)
                } else if concept.body.range(of: query, options: .caseInsensitive) != nil {
                    weak.append(line)
                }
            }
        }

        let hits = strong + weak
        guard !hits.isEmpty else {
            return "No concepts match “\(query)”."
        }
        var text = hits.prefix(20).joined(separator: "\n")
        if hits.count > 20 {
            text += "\n(\(hits.count - 20) more matches — refine the query.)"
        }
        return text
    }

    private func entryLine(for concept: KnowledgeConcept, in bundle: KnowledgeBundle, qualify: Bool) -> String {
        var line = "- \(concept.path) [\(concept.typeName)]"
        if let title = concept.title, !title.isEmpty { line += " \(title)" }
        if let summary = concept.summary, !summary.isEmpty { line += " — \(summary)" }
        if qualify { line += " (bundle: \(bundle.name))" }
        return line
    }

    // MARK: - knowledge__read

    private func read(conceptID: String, bundleName: String?, bundles: [KnowledgeBundle]) throws -> String {
        // Tolerate ids passed with the .md suffix or a leading slash.
        var id = conceptID
        if id.hasSuffix(".md") { id = String(id.dropLast(3)) }
        if id.hasPrefix("/") { id = String(id.dropFirst()) }

        let scope = bundleName.map { name in bundles.filter { $0.name == name } } ?? bundles
        let matches = scope.compactMap { bundle in
            bundle.concept(atPath: id).map { (bundle, $0) }
        }

        guard var chosen = matches.first else {
            throw ToolError.conceptNotFound(conceptID)
        }
        var note = ""
        if matches.count > 1 {
            let names = Set(matches.map { $0.0.name })
            if bundleName == nil, names.count > 1 {
                return "Concept “\(id)” exists in several bundles (\(names.sorted().joined(separator: ", "))). Call again with the `bundle` argument."
            }
            // Same-named bundles can't be told apart by the `bundle`
            // argument; read the freshest copy instead of looping on an
            // unresolvable ambiguity message.
            chosen = matches.max { $0.1.updatedAt < $1.1.updatedAt } ?? chosen
            note = "Note: \(matches.count) documents share this id; showing the most recently updated.\n\n"
        }
        let (bundle, concept) = chosen

        var text = note + "Concept: \(concept.path) (bundle: \(bundle.name))\n\n"
        text += KnowledgeTransfer.serializedContents(for: concept)
        if text.count > Self.readCharacterLimit {
            let overflow = text.count - Self.readCharacterLimit
            text = String(text.prefix(Self.readCharacterLimit))
                + "\n… [truncated \(overflow) characters]"
        }
        return text
    }

    // MARK: - Helpers

    /// Resolves bundle IDs, silently skipping dangling references (a bundle
    /// deleted on another device may still be listed on an agent). Scoped at
    /// the database instead of fetching every bundle per call.
    private func bundles(for ids: [UUID], context: ModelContext) -> [KnowledgeBundle] {
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<KnowledgeBundle>(
            predicate: #Predicate { ids.contains($0.id) },
            sortBy: [SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
