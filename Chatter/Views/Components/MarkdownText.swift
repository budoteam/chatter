import SwiftUI

/// Lightweight block-level Markdown renderer for chat output. Supports
/// paragraphs, headings, fenced code blocks, tables, bullet/numbered lists,
/// quotes, and dividers; inline styling (bold, italic, `code`, links) is
/// handled by `AttributedString`. Font/foreground are inherited from the
/// environment so callers can restyle (e.g. secondary callout for steps).
struct MarkdownText: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let string):
            Text(Self.inline(string))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let string):
            Text(Self.inline(string))
                .font(headingFont(level))
                .textSelection(.enabled)
                .padding(.top, 2)

        case .code(let language, let content):
            CodeBlockView(language: language, content: content)

        case .table(let header, let rows):
            tableView(header: header, rows: rows)

        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ordered ? "\(i + 1)." : "•")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        Text(Self.inline(items[i]))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .quote(let string):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent.opacity(0.5))
                    .frame(width: 3)
                Text(Self.inline(string))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .divider:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }

    private func tableView(header: [String], rows: [[String]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        tableCell(header.indices.contains(c) ? header[c] : "", isHeader: true)
                    }
                }
                ForEach(rows.indices, id: \.self) { r in
                    Divider()
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            tableCell(rows[r].indices.contains(c) ? rows[r][c] : "", isHeader: false)
                        }
                    }
                }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        )
    }

    private func tableCell(_ string: String, isHeader: Bool) -> some View {
        Text(Self.inline(string))
            .font(.callout.weight(isHeader ? .semibold : .regular))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 340, alignment: .leading)
            .gridColumnAlignment(.leading)
            .background(isHeader ? AnyShapeStyle(Theme.surfaceRaised) : AnyShapeStyle(.clear))
    }

    // MARK: - Inline

    static func inline(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }
}

// MARK: - Parser

enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, content: String)
    case table(header: [String], rows: [[String]])
    case list(ordered: Bool, items: [String])
    case quote(String)
    case divider
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = text.components(separatedBy: "\n")

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if line.hasPrefix("```") {
                flushParagraph()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1  // skip closing fence
                blocks.append(.code(
                    language: language.isEmpty ? nil : language,
                    content: code.joined(separator: "\n")
                ))
                continue
            }

            // Blank line ends the current paragraph
            if line.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Table: needs a header row and a |---| separator row
            if line.hasPrefix("|") {
                var tableLines: [String] = []
                var j = i
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    tableLines.append(t)
                    j += 1
                }
                if let table = parseTable(tableLines) {
                    flushParagraph()
                    blocks.append(table)
                    i = j
                    continue
                }
                // Not a valid table — fall through to paragraph handling.
            }

            // Heading
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.count > level,
                   line[line.index(line.startIndex, offsetBy: level)] == " " {
                    flushParagraph()
                    let content = String(line.dropFirst(level + 1))
                    blocks.append(.heading(level: level, text: content))
                    i += 1
                    continue
                }
            }

            // Divider
            if line.count >= 3, Set(line) == ["-"] || Set(line) == ["*"] || Set(line) == ["_"] {
                flushParagraph()
                blocks.append(.divider)
                i += 1
                continue
            }

            // Quote
            if line.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    quoteLines.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            // Lists
            if let item = bulletItem(line) {
                flushParagraph()
                var items = [item]
                i += 1
                while i < lines.count,
                      let next = bulletItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    i += 1
                }
                blocks.append(.list(ordered: false, items: items))
                continue
            }
            if let item = numberedItem(line) {
                flushParagraph()
                var items = [item]
                i += 1
                while i < lines.count,
                      let next = numberedItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    i += 1
                }
                blocks.append(.list(ordered: true, items: items))
                continue
            }

            paragraph.append(raw)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: Helpers

    private static func bulletItem(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    private static func parseTable(_ tableLines: [String]) -> MarkdownBlock? {
        guard tableLines.count >= 2 else { return nil }
        let separator = tableLines[1]
        let separatorChars = Set(separator)
        guard separator.contains("-"),
              separatorChars.isSubset(of: ["|", "-", ":", " "]) else { return nil }

        let header = cells(tableLines[0])
        let rows = tableLines.dropFirst(2).map(cells)
        guard !header.isEmpty else { return nil }
        return .table(header: header, rows: Array(rows))
    }

    private static func cells(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
