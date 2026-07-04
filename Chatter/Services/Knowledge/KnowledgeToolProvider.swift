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

    private static let toolPrefix = "knowledge__"
    /// Keeps the system-prompt overview from crowding out the conversation.
    private static let overviewCharacterLimit = 3_000
    /// Keeps a single tool result within a sane share of the context window.
    private static let readCharacterLimit = 16_000

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
    /// prompt. Returns nil when the agent has no (resolvable) bundles.
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
            var section = "\n\n## Knowledge bundle: \(bundle.name)\n"
            let index = bundle.concept(atPath: "index")?.body
                ?? KnowledgeTransfer.generatedRootIndex(for: bundle)
            section += index.trimmingCharacters(in: .whitespacesAndNewlines)

            if text.count + section.count > Self.overviewCharacterLimit {
                text += "\n\n(Overview truncated — use \(Self.listToolName) to see the rest.)"
                break
            }
            text += section
        }
        return text
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

    func canHandle(_ namespacedName: String) -> Bool {
        namespacedName.hasPrefix(Self.toolPrefix)
    }

    // MARK: - Dispatch

    func call(
        namespacedName: String,
        argumentsJSON: String,
        bundleIDs: [UUID],
        context: ModelContext
    ) throws -> String {
        let bundles = bundles(for: bundleIDs, context: context)
        let args = arguments(from: argumentsJSON)

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
            let index = bundle.concept(atPath: "index")?.body
                ?? KnowledgeTransfer.generatedRootIndex(for: bundle)
            return "# Bundle: \(bundle.name)\n"
                + index.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .joined(separator: "\n\n")
    }

    private func search(query: String, bundles: [KnowledgeBundle]) -> String {
        let needle = query.lowercased()
        var strong: [String] = []  // hits in id/title/type/tags/description
        var weak: [String] = []    // body-only hits

        for bundle in bundles {
            for concept in bundle.conceptDocuments {
                let metadata = (
                    [concept.path, concept.title ?? "", concept.typeName, concept.summary ?? ""]
                        + concept.tags
                )
                .joined(separator: " ")
                .lowercased()
                let line = entryLine(for: concept, in: bundle, qualify: bundles.count > 1)
                if metadata.contains(needle) {
                    strong.append(line)
                } else if concept.body.lowercased().contains(needle) {
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

        guard let (bundle, concept) = matches.first else {
            throw ToolError.conceptNotFound(conceptID)
        }
        if matches.count > 1 {
            let names = matches.map { $0.0.name }.joined(separator: ", ")
            return "Concept “\(id)” exists in several bundles (\(names)). Call again with the `bundle` argument."
        }

        var text = "Concept: \(concept.path) (bundle: \(bundle.name))\n\n"
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
    /// deleted on another device may still be listed on an agent).
    private func bundles(for ids: [UUID], context: ModelContext) -> [KnowledgeBundle] {
        guard !ids.isEmpty else { return [] }
        let all = (try? context.fetch(FetchDescriptor<KnowledgeBundle>())) ?? []
        let wanted = Set(ids)
        return all.filter { wanted.contains($0.id) }.sorted { $0.name < $1.name }
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
