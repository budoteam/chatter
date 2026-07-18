import Foundation

/// Built-in research tools backed by ollama.com's web search API: the model
/// can search the web (`web_search`) and read single pages (`web_fetch`).
/// Offered per agent (`Agent.webAccessEnabled`) and only while an API key is
/// present; ChatEngine routes calls here by the exact tool names.
struct WebToolProvider {
    static let searchToolName = "web_search"
    static let fetchToolName = "web_fetch"

    /// Caps keep tool results from flooding the context window.
    private static let maxSearchResults = 5
    private static let maxSnippetLength = 2_000
    private static let maxPageLength = 16_000
    private static let maxLinks = 40

    let ollama: OllamaServiceProtocol

    // MARK: - Tool definitions

    func tools() -> [OllamaTool] {
        [
            OllamaTool(function: .init(
                name: Self.searchToolName,
                description: "Search the web. Returns result titles, URLs, and content snippets. Use \(Self.fetchToolName) to read a promising result in full.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("The search query."),
                        ]),
                    ]),
                    "required": .array([.string("query")]),
                ])
            )),
            OllamaTool(function: .init(
                name: Self.fetchToolName,
                description: "Fetch a single web page and return its main content plus the links found on it.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url": .object([
                            "type": .string("string"),
                            "description": .string("The URL to fetch, e.g. \"https://example.com/article\"."),
                        ]),
                    ]),
                    "required": .array([.string("url")]),
                ])
            )),
        ]
    }

    // MARK: - Dispatch

    func call(name: String, argumentsJSON: String) async throws -> String {
        let args = JSONValue.parse(argumentsJSON).stringArguments
        switch name {
        case Self.searchToolName:
            guard let query = args["query"], !query.isEmpty else {
                throw ToolError.missingArgument("query")
            }
            return try await search(query: query)
        case Self.fetchToolName:
            guard let url = args["url"], !url.isEmpty else {
                throw ToolError.missingArgument("url")
            }
            return try await fetch(url: url)
        default:
            throw ToolError.unknownTool(name)
        }
    }

    private func search(query: String) async throws -> String {
        let response = try await ollama.webSearch(query: query, maxResults: Self.maxSearchResults)
        let results = response.results ?? []
        guard !results.isEmpty else { return "No results found for “\(query)”." }
        return results.enumerated().map { index, result in
            var lines = ["[\(index + 1)] \(result.title ?? "Untitled")"]
            if let url = result.url, !url.isEmpty { lines.append(url) }
            if let content = result.content, !content.isEmpty {
                lines.append(String(content.prefix(Self.maxSnippetLength)))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func fetch(url: String) async throws -> String {
        let response = try await ollama.webFetch(url: url)
        var sections: [String] = []
        if let title = response.title, !title.isEmpty {
            sections.append("# \(title)")
        }
        if let content = response.content, !content.isEmpty {
            var text = String(content.prefix(Self.maxPageLength))
            if content.count > Self.maxPageLength { text += "\n…(truncated)" }
            sections.append(text)
        }
        if let links = response.links, !links.isEmpty {
            sections.append("Links:\n" + links.prefix(Self.maxLinks).joined(separator: "\n"))
        }
        return sections.isEmpty ? "The page returned no readable content." : sections.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    enum ToolError: LocalizedError {
        case unknownTool(String)
        case missingArgument(String)

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name): return "Unknown web tool “\(name)”."
            case .missingArgument(let name): return "Missing required argument “\(name)”."
            }
        }
    }
}
