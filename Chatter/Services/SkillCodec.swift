import Foundation

/// Reads and writes the single-skill markdown file format used by skill
/// export/import: flat YAML frontmatter (`name`, `description`) followed by
/// the markdown body. Deliberately separate from `OKFCodec` — OKF requires
/// `type`/`title` keys and round-trips foreign keys verbatim, neither of
/// which fits skill files.
///
/// ```markdown
/// ---
/// name: weekly-report
/// description: One line summary
/// ---
///
/// <content markdown>
/// ```
enum SkillCodec {
    struct ParsedSkill {
        /// Raw `name:` value; nil when the file has no usable frontmatter
        /// (callers fall back to the file name stem). Callers slugify.
        var name: String?
        var summary: String = ""
        var content: String = ""
        /// Non-fatal conformance issues found while parsing.
        var warnings: [String] = []
    }

    // MARK: - Serialize

    static func serialize(name: String, summary: String, content: String) -> String {
        var lines = ["---", "name: \(quoteIfNeeded(name))"]
        if !summary.isEmpty {
            lines.append("description: \(quoteIfNeeded(summary))")
        }
        lines.append("---")
        var text = lines.joined(separator: "\n") + "\n"
        if !content.isEmpty {
            // Exactly one blank line before a non-empty body; parse() strips
            // it again so the pair stays deterministic.
            text += "\n" + content
        }
        return text
    }

    // MARK: - Parse

    static func parse(fileName: String, contents: String) -> ParsedSkill {
        // Line endings are normalized once (export always writes LF); a UTF-8
        // BOM would otherwise hide the opening frontmatter fence.
        var text = contents.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---",
              let closeIndex = lines.dropFirst().firstIndex(of: "---")
        else {
            return ParsedSkill(
                name: nil, content: text,
                warnings: ["\(fileName): missing frontmatter; name taken from file name"]
            )
        }

        var parsed = ParsedSkill()
        for line in lines[1..<closeIndex] {
            guard let (key, value) = keyLine(line) else { continue }
            switch key {
            case "name":
                parsed.name = unquote(value)
            case "description", "summary":
                // `summary` is tolerated as an alias for `description`.
                parsed.summary = unquote(value)
            default:
                break  // Unknown keys are ours to ignore — no round-tripping.
            }
        }
        if parsed.name == nil {
            parsed.warnings.append("\(fileName): frontmatter has no \"name\"; name taken from file name")
        }

        var body = lines[(closeIndex + 1)...].joined(separator: "\n")
        if body.hasPrefix("\n") { body.removeFirst() }
        parsed.content = body
        return parsed
    }

    /// Matches `key: value` / `key:` at zero indentation with a simple key.
    private static func keyLine(_ line: String) -> (key: String, value: String)? {
        guard let first = line.first, first != " ", first != "\t", first != "#" else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon])
        guard !key.isEmpty,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" })
        else { return nil }
        let value = String(line[line.index(after: colon)...])
        // YAML requires a space (or end of line) after the key colon.
        guard value.isEmpty || value.hasPrefix(" ") || value.hasPrefix("\t") else { return nil }
        return (key, value.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Scalar quoting (mirrors OKFCodec's private helpers)

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

    /// Quotes a scalar when emitting it bare would change its YAML meaning.
    private static func quoteIfNeeded(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
        let boolLike = ["true", "false", "null", "~", "yes", "no", "on", "off"]
        let indicators = "!&*?|>%@`\"'#-[]{},:"
        let needsQuoting = boolLike.contains(value.lowercased())
            || Double(value) != nil
            || value.first.map { indicators.contains($0) } ?? false
            || value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.contains(": ") || value.contains(" #")
            || value.hasSuffix(":")
        guard needsQuoting else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
