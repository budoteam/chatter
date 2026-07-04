import Foundation

/// Parsed frontmatter of an OKF concept document. Known OKF keys are typed;
/// everything else is preserved verbatim in `extraFields`.
struct OKFFrontmatter {
    var type: String = "unknown"
    var title: String?
    /// The OKF `description` key.
    var summary: String?
    var resource: String?
    var tags: [String] = []
    /// Verbatim `timestamp` value (ISO 8601 by convention, never reformatted).
    var timestampRaw: String?
    var extraFields: [OKFExtraField] = []
}

/// One markdown file of an OKF bundle, decoupled from SwiftData so the codec
/// is testable and reusable for import and export.
struct OKFDocument {
    /// Bundle-relative file path, e.g. "tables/users.md".
    var relativePath: String
    var kind: KnowledgeDocKind
    /// nil for reserved files (index/log), which carry no frontmatter.
    var frontmatter: OKFFrontmatter?
    var body: String
    /// Non-fatal conformance issues found while parsing.
    var warnings: [String] = []
}

/// Reads and writes OKF v0.1 concept documents (markdown + YAML frontmatter).
///
/// The parser handles the flat YAML subset the OKF spec uses and keeps every
/// construct it does not model — unknown keys, comments, block scalars — as
/// verbatim raw line blocks, so foreign bundles survive an import/export
/// round-trip without information loss. Known keys are re-emitted in canonical
/// order (`type, title, description, resource, tags, timestamp`); files that
/// already use that order round-trip byte-identically (modulo CRLF → LF).
enum OKFCodec {
    private static let knownKeys: Set<String> = [
        "type", "title", "description", "resource", "tags", "timestamp",
    ]

    // MARK: - Parse

    static func parse(path: String, contents: String) -> OKFDocument {
        // Line endings are normalized once; export always writes LF.
        let text = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let fileName = path.split(separator: "/").last.map(String.init) ?? path

        if fileName == "index.md" {
            return OKFDocument(relativePath: path, kind: .index, frontmatter: nil, body: text)
        }
        if fileName == "log.md" {
            return OKFDocument(relativePath: path, kind: .log, frontmatter: nil, body: text)
        }

        var lines = text.components(separatedBy: "\n")
        // `components` yields a trailing "" for a trailing newline; keep track
        // by working on the raw text offsets instead: find the frontmatter
        // block line-wise, then take the body as a substring.
        guard lines.first == "---" else {
            return OKFDocument(
                relativePath: path, kind: .concept,
                frontmatter: OKFFrontmatter(),
                body: text,
                warnings: ["\(path): missing frontmatter block; treated as type \"unknown\""]
            )
        }
        guard let closeIndex = lines.dropFirst().firstIndex(of: "---") else {
            return OKFDocument(
                relativePath: path, kind: .concept,
                frontmatter: OKFFrontmatter(),
                body: text,
                warnings: ["\(path): unterminated frontmatter block; treated as type \"unknown\""]
            )
        }

        let frontmatterLines = Array(lines[1..<closeIndex])
        var body = lines[(closeIndex + 1)...].joined(separator: "\n")
        // Serialization inserts exactly one blank line before a non-empty
        // body; drop it here so the pair stays deterministic.
        if body.hasPrefix("\n") { body.removeFirst() }
        lines = []  // free

        var warnings: [String] = []
        let frontmatter = parseFrontmatter(frontmatterLines, path: path, warnings: &warnings)
        return OKFDocument(
            relativePath: path, kind: .concept,
            frontmatter: frontmatter, body: body, warnings: warnings
        )
    }

    private static func parseFrontmatter(
        _ lines: [String], path: String, warnings: inout [String]
    ) -> OKFFrontmatter {
        var fm = OKFFrontmatter()
        var seen: Set<String> = []

        for block in blocks(from: lines) {
            guard let key = block.key else {
                // Preamble/comment lines before the first key: preserve verbatim.
                fm.extraFields.append(OKFExtraField(key: "#", rawBlock: block.raw))
                continue
            }
            guard knownKeys.contains(key), !seen.contains(key) else {
                if seen.contains(key) {
                    warnings.append("\(path): duplicate key \"\(key)\" kept verbatim")
                }
                fm.extraFields.append(OKFExtraField(key: key, rawBlock: block.raw))
                continue
            }

            let inline = block.inlineValue.trimmingCharacters(in: .whitespaces)
            // Block scalars (| / >) and nested structures under known keys are
            // beyond the flat subset we model — preserve them verbatim instead
            // of corrupting them.
            let isBlockScalar = inline.hasPrefix("|") || inline.hasPrefix(">")
            let hasContinuation = block.continuationLines.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if isBlockScalar || (key != "tags" && hasContinuation) {
                fm.extraFields.append(OKFExtraField(key: key, rawBlock: block.raw))
                continue
            }
            seen.insert(key)

            switch key {
            case "type": fm.type = unquote(inline)
            case "title": fm.title = unquote(inline)
            case "description": fm.summary = unquote(inline)
            case "resource": fm.resource = unquote(inline)
            case "timestamp": fm.timestampRaw = unquote(inline)
            case "tags": fm.tags = parseTags(inline: inline, continuation: block.continuationLines)
            default: break
            }
        }

        if fm.type.isEmpty {
            warnings.append("\(path): missing or empty required \"type\"; treated as \"unknown\"")
            fm.type = "unknown"
        }
        return fm
    }

    /// Groups frontmatter lines into blocks: each zero-indent `key:` line
    /// starts a block; everything else (indented lines, list items, comments,
    /// blanks) belongs to the preceding block.
    private struct Block {
        var key: String?
        var inlineValue: String = ""
        var continuationLines: [String] = []
        var rawLines: [String] = []
        var raw: String { rawLines.joined(separator: "\n") }
    }

    private static func blocks(from lines: [String]) -> [Block] {
        var result: [Block] = []
        var current: Block?

        for line in lines {
            if let (key, value) = keyLine(line) {
                if let block = current { result.append(block) }
                current = Block(key: key, inlineValue: value, rawLines: [line])
            } else if current != nil {
                current!.continuationLines.append(line)
                current!.rawLines.append(line)
            } else {
                current = Block(key: nil, rawLines: [line])
            }
        }
        if let block = current { result.append(block) }
        return result
    }

    /// Matches `key: value` / `key:` at zero indentation with a simple key
    /// (letters, digits, `_ . -`). Returns nil for anything else.
    private static func keyLine(_ line: String) -> (key: String, value: String)? {
        guard let first = line.first, first != " ", first != "\t", first != "#" else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon])
        guard !key.isEmpty,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" })
        else { return nil }
        let after = line.index(after: colon)
        let value = String(line[after...])
        // YAML requires a space (or end of line) after the key colon.
        guard value.isEmpty || value.hasPrefix(" ") || value.hasPrefix("\t") else { return nil }
        return (key, value)
    }

    private static func parseTags(inline: String, continuation: [String]) -> [String] {
        if inline.hasPrefix("["), inline.hasSuffix("]") {
            return splitFlowList(String(inline.dropFirst().dropLast())).map(unquote)
        }
        if !inline.isEmpty {
            // Scalar tags value: tolerate as a single tag.
            return [unquote(inline)]
        }
        return continuation.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed == "-" else { return nil }
            return unquote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
    }

    /// Splits a flow list body on top-level commas, respecting quotes.
    private static func splitFlowList(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for ch in text {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "," {
                items.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        items.append(current)
        return items
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
            return String(v.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") {
            return String(v.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return v
    }

    // MARK: - Serialize

    static func serialize(_ doc: OKFDocument) -> String {
        switch doc.kind {
        case .index, .log:
            return doc.body
        case .concept:
            let fm = doc.frontmatter ?? OKFFrontmatter()
            var lines: [String] = ["---"]
            lines.append("type: \(quoteIfNeeded(fm.type))")
            if let title = fm.title, !title.isEmpty {
                lines.append("title: \(quoteIfNeeded(title))")
            }
            if let summary = fm.summary, !summary.isEmpty {
                lines.append("description: \(quoteIfNeeded(summary))")
            }
            if let resource = fm.resource, !resource.isEmpty {
                lines.append("resource: \(quoteIfNeeded(resource))")
            }
            if !fm.tags.isEmpty {
                let items = fm.tags.map { quoteIfNeeded($0, inFlowList: true) }
                lines.append("tags: [\(items.joined(separator: ", "))]")
            }
            if let timestamp = fm.timestampRaw, !timestamp.isEmpty {
                lines.append("timestamp: \(quoteIfNeeded(timestamp))")
            }
            for extra in fm.extraFields {
                lines.append(extra.rawBlock)
            }
            lines.append("---")
            var text = lines.joined(separator: "\n") + "\n"
            if !doc.body.isEmpty {
                text += "\n" + doc.body
            }
            return text
        }
    }

    /// Quotes a scalar when emitting it bare would change its YAML meaning.
    private static func quoteIfNeeded(_ value: String, inFlowList: Bool = false) -> String {
        if value.isEmpty { return "\"\"" }
        let lowered = value.lowercased()
        let boolLike = ["true", "false", "null", "~", "yes", "no", "on", "off"]
        let indicators = "!&*?|>%@`\"'#-[]{},:"
        var needsQuoting = boolLike.contains(lowered)
            || Double(value) != nil
            || value.first.map { indicators.contains($0) } ?? false
            || value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.contains(": ") || value.contains(" #")
            || value.hasSuffix(":")
        if inFlowList {
            needsQuoting = needsQuoting || value.contains(",")
                || value.contains("[") || value.contains("]")
        }
        guard needsQuoting else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
