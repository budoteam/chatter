import SwiftUI

/// Lightweight block-level Markdown renderer for chat output. Supports
/// paragraphs, headings, fenced code blocks, tables, bullet/numbered lists,
/// quotes, and dividers; inline styling (bold, italic, `code`, links) is
/// handled by `AttributedString`. Font/foreground are inherited from the
/// environment so callers can restyle (e.g. secondary callout for steps).
struct MarkdownText: View {
    let text: String
    /// Non-nil renders `choices` blocks as tappable quick-reply chips (the
    /// tap sends the option as the user's reply). Nil — history, streaming,
    /// watchOS — falls back to a plain bullet list.
    var onChoice: ((String) -> Void)? = nil

    var body: some View {
        let blocks = Self.parsedBlocks(text)
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
            listView(ordered: ordered, items: items)

        case .choices(let options):
            if let onChoice {
                ChoiceChipsView(options: options, onPick: onChoice)
            } else {
                listView(ordered: false, items: options)
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

        case .image(let alt, let url):
            InlineImageView(alt: alt, urlString: url)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return Theme.Typography.font(.title1)
        case 2: return Theme.Typography.font(.title2)
        default: return Theme.Typography.font(.title3)
        }
    }

    private func listView(ordered: Bool, items: [String]) -> some View {
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
            .font(Theme.Typography.font(.callout).weight(isHeader ? .semibold : .regular))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 340, alignment: .leading)
            .gridColumnAlignment(.leading)
            .background(isHeader ? AnyShapeStyle(Theme.surfaceRaised) : AnyShapeStyle(.clear))
    }

    // MARK: - Caching

    @MainActor
    private static func parsedBlocks(_ text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = MarkdownCache.blocks.object(forKey: key) { return hit.value }
        let blocks = MarkdownParser.parse(text)
        MarkdownCache.blocks.setObject(.init(blocks), forKey: key, cost: text.utf16.count)
        return blocks
    }

    // MARK: - Inline

    @MainActor
    static func inline(_ string: String) -> AttributedString {
        let key = string as NSString
        if let hit = MarkdownCache.inline.object(forKey: key) { return hit.value }
        let attributed = (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
        MarkdownCache.inline.setObject(.init(attributed), forKey: key)
        return attributed
    }
}

/// Memoizes the two expensive steps of rendering. A streaming message
/// re-renders at ~12 Hz and would otherwise re-parse its entire accumulated
/// text and rebuild `AttributedString(markdown:)` for every block on the main
/// thread — O(n²) over the answer length. Completed blocks never change, so
/// the per-string inline cache reduces each flush to lookups plus one
/// conversion for the still-growing block.
@MainActor
private enum MarkdownCache {
    final class Box<T> {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Full text → parsed blocks. Streaming inserts a near-duplicate entry
    /// per flush, hence the cost bound (UTF-16 length, ~4 MB total).
    static let blocks: NSCache<NSString, Box<[MarkdownBlock]>> = {
        let cache = NSCache<NSString, Box<[MarkdownBlock]>>()
        cache.countLimit = 64
        cache.totalCostLimit = 4 << 20
        return cache
    }()

    /// Block source string → inline-styled string (the dominant cost).
    static let inline: NSCache<NSString, Box<AttributedString>> = {
        let cache = NSCache<NSString, Box<AttributedString>>()
        cache.countLimit = 2048
        return cache
    }()
}

// MARK: - Parser

enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, content: String)
    case table(header: [String], rows: [[String]])
    case list(ordered: Bool, items: [String])
    case quote(String)
    case image(alt: String, url: String)
    case divider
    /// Quick-reply options from a ```choices fence (UI convention, see
    /// ChatEngine's system prompt section) — rendered as tappable chips.
    case choices([String])
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
                // A "choices" fence is a UI convention, not code: quick-reply
                // options, one per line (see ChatEngine's system prompt).
                // Capped so a rambling model can't flood the chat with chips.
                if language.lowercased() == "choices" {
                    let options = code
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if !options.isEmpty {
                        blocks.append(.choices(Array(options.prefix(6))))
                    }
                    continue
                }
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

            // Standalone image: a line consisting only of ![alt](url). The
            // strict whole-line match keeps streaming-safe: a half-typed
            // `![alt](https://exa` simply falls through to paragraph.
            if let image = imageLine(line) {
                flushParagraph()
                blocks.append(.image(alt: image.alt, url: image.url))
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

    /// Matches `![alt](url)` spanning the whole line. Only http(s) and
    /// `data:image/…;base64,` URLs are accepted; anything else stays a
    /// paragraph so inline rendering handles it as before.
    private static func imageLine(_ line: String) -> (alt: String, url: String)? {
        guard line.hasPrefix("!["), line.hasSuffix(")") else { return nil }
        guard let closeBracket = line.firstIndex(of: "]") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<closeBracket])
        let rest = line[line.index(after: closeBracket)...]
        guard rest.hasPrefix("("), rest.hasSuffix(")") else { return nil }
        let url = String(rest.dropFirst().dropLast())
        guard !url.isEmpty, !url.contains(" "), !url.contains("\"") else { return nil }
        let lower = url.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://")
                || lower.hasPrefix("data:image/") else { return nil }
        return (alt, url)
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

// MARK: - Quick-reply chips

/// Tappable options for a `choices` block — the tap sends the option as the
/// user's reply. Capsule styling matches the composer's agent/model pills.
private struct ChoiceChipsView: View {
    let options: [String]
    let onPick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    Button { onPick(option) } label: {
                        Text(option)
                            .font(Theme.Typography.font(.callout).weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.surfaceRaised, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
