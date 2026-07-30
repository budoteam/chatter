import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Renders one artifact: CSV as a table, markdown via the chat renderer,
/// code as selectable monospace text — or inline SVG when the artifact name
/// ends in .svg. Shared by the macOS inspector and the iOS sheet — both
/// differ only in the container, not the content.
struct ArtifactPaneView: View {
    let artifact: Artifact

    @Environment(AppEnvironment.self) private var env

    @State private var showExporter = false
    @State private var exportDocument: CodeFileDocument?
    @State private var showSource = false

    private var isSVG: Bool {
        (artifact.name as NSString).pathExtension.lowercased() == "svg"
    }

    private var exportType: UTType {
        UTType(filenameExtension: (artifact.name as NSString).pathExtension) ?? .plainText
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        #if os(macOS)
        .frame(minWidth: 320)
        #endif
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: artifact.name
        ) { _ in }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: artifact.kind.iconName)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.name)
                    .font(Theme.Typography.font(.title2))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(artifact.kind.label) · \(sizeString)")
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isSVG {
                Button {
                    showSource.toggle()
                } label: {
                    Image(systemName: showSource ? "eye" : "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.plain)
                .help(showSource ? "Show preview" : "Show source")
                .accessibilityLabel(Text(showSource ? "Show preview" : "Show source"))
            }
            Button {
                exportDocument = CodeFileDocument(text: artifact.content)
                showExporter = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .help("Save as file")
            .accessibilityLabel(Text("Save as file"))
            ShareLink(item: artifact.content) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .help("Share")
            .accessibilityLabel(Text("Share"))
            Button { env.openArtifactID = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch artifact.kind {
        case .csv:
            if let table = CSVTable.parse(artifact.content) {
                CSVTableView(table: table)
            } else {
                rawContent(note: "CSV parse failed — showing raw content.")
            }
        case .markdown:
            ScrollView {
                MarkdownText(text: artifact.content)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .code:
            if isSVG && !showSource {
                ScrollView {
                    SVGView(svg: artifact.content)
                        .padding(16)
                }
            } else {
                rawContent(note: nil)
            }
        }
    }

    private func rawContent(note: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let note {
                    Text(note)
                        .font(Theme.Typography.font(.caption))
                        .foregroundStyle(.secondary)
                }
                Text(artifact.content)
                    .font(Theme.Typography.font(.mono))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
    }

    private var sizeString: String {
        String(format: "%.1f KB", Double(artifact.content.utf8.count) / 1000)
    }
}

extension ArtifactKind {
    var iconName: String {
        switch self {
        case .csv: return "tablecells"
        case .markdown: return "doc.richtext"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var label: String {
        switch self {
        case .csv: return "CSV"
        case .markdown: return "Markdown"
        case .code: return "Code"
        }
    }
}

// MARK: - CSV rendering

/// Minimal RFC-4180-ish parse: quoted fields, `""` escapes, CR/LF line ends.
/// Returns nil when the shape is not a usable table (no header row or
/// ragged column counts) so the caller can fall back to the raw view.
struct CSVTable {
    let header: [String]
    let rows: [[String]]

    /// Display cap keeps giant generated tables from materializing thousands
    /// of grid cells at once.
    static let maxRenderedRows = 500

    static func parse(_ content: String) -> CSVTable? {
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var index = content.startIndex

        func endField() {
            record.append(field)
            field = ""
        }
        func endRecord() {
            endField()
            records.append(record)
            record = []
        }

        while index < content.endIndex {
            let char = content[index]
            if inQuotes {
                if char == "\"" {
                    let next = content.index(after: index)
                    if next < content.endIndex && content[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else if char == "\"" && field.isEmpty {
                inQuotes = true
            } else if char == "," {
                endField()
            } else if char == "\n" || char == "\r" {
                endRecord()
                // Swallow the LF of a CRLF pair.
                if char == "\r" {
                    let next = content.index(after: index)
                    if next < content.endIndex && content[next] == "\n" { index = next }
                }
            } else {
                field.append(char)
            }
            index = content.index(after: index)
        }
        // Trailing field/record when the file doesn't end with a newline.
        if !field.isEmpty || !record.isEmpty { endRecord() }
        // Drop blank trailing/short lines (e.g. a final empty line).
        records.removeAll { $0.count == 1 && $0[0].isEmpty }

        guard let header = records.first, header.count > 1, records.count > 1 else { return nil }
        let body = records.dropFirst()
        guard body.allSatisfy({ $0.count == header.count }) else { return nil }
        return CSVTable(header: header, rows: Array(body))
    }
}

private struct CSVTableView: View {
    let table: CSVTable

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(table.header.indices, id: \.self) { column in
                            cell(table.header[column], isHeader: true)
                        }
                    }
                    ForEach(table.rows.prefix(CSVTable.maxRenderedRows).indices, id: \.self) { row in
                        GridRow {
                            ForEach(table.rows[row].indices, id: \.self) { column in
                                cell(table.rows[row][column], isHeader: false)
                            }
                        }
                    }
                }
                if table.rows.count > CSVTable.maxRenderedRows {
                    Text("… \(table.rows.count - CSVTable.maxRenderedRows) more rows (use Share to export the full file)")
                        .font(Theme.Typography.font(.caption))
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
        }
    }

    private func cell(_ string: String, isHeader: Bool) -> some View {
        Text(string)
            .font(isHeader ? Theme.Typography.font(.callout).weight(.semibold) : Theme.Typography.font(.callout))
            .foregroundStyle(isHeader ? .primary : .secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // Natural width (not maxWidth: .infinity) so wide tables actually
            // scroll horizontally instead of truncating every column.
            .background(isHeader ? Theme.surfaceRaised : .clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.separator).frame(height: 0.5)
            }
    }
}
