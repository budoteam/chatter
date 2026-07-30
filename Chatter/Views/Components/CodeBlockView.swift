import SwiftUI
import UniformTypeIdentifiers

/// Maps a fenced code block's language tag to an export file type, so
/// model-generated data (```csv, ```json, …) saves with the right extension.
enum CodeFileType {
    private static let extensions: [String: String] = [
        "csv": "csv", "tsv": "tsv", "json": "json",
        "yaml": "yaml", "yml": "yaml", "xml": "xml", "html": "html",
        "md": "md", "markdown": "md",
        "swift": "swift", "python": "py", "py": "py",
        "javascript": "js", "js": "js", "typescript": "ts", "ts": "ts",
        "sh": "sh", "bash": "sh", "zsh": "sh", "shell": "sh",
        "sql": "sql", "c": "c", "cpp": "cpp", "c++": "cpp",
        "java": "java", "kotlin": "kt", "ruby": "rb", "rb": "rb",
        "go": "go", "rust": "rs", "rs": "rs", "php": "php",
        "toml": "toml", "diff": "patch", "patch": "patch",
        "svg": "svg", "png": "png", "jpg": "jpg", "jpeg": "jpg",
        "gif": "gif", "webp": "webp",
    ]

    static func fileExtension(for language: String?) -> String {
        guard let language = language?.lowercased(), !language.isEmpty else { return "txt" }
        return extensions[language] ?? "txt"
    }

    static func utType(for language: String?) -> UTType {
        UTType(filenameExtension: fileExtension(for: language)) ?? .plainText
    }
}

/// Export-only document for one code block's text; the concrete type is
/// passed per `fileExporter` call (everything we export descends from
/// public.data).
struct CodeFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// One fenced code block: language caption plus copy/save buttons over the
/// horizontally scrolling monospaced body. Self-contained — each block owns
/// its `fileExporter`, so it works wherever `MarkdownText` renders (chat,
/// thinking traces, tool steps) without any coordinator plumbing.
struct CodeBlockView: View {
    let language: String?
    let content: String

    @State private var showExporter = false
    @State private var exportDocument: CodeFileDocument?
    @State private var exportFilename = ""
    @State private var showCode = false

    /// ```svg fences render inline via SVGView; the header toggle switches
    /// back to the raw source.
    private var isSVG: Bool { language?.lowercased() == "svg" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(Theme.Typography.font(.caption).weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if isSVG {
                    headerButton(
                        showCode ? "eye" : "chevron.left.forwardslash.chevron.right",
                        help: showCode ? "Show preview" : "Show code"
                    ) {
                        showCode.toggle()
                    }
                }
                CopyButton(help: "Copy code") { Pasteboard.copy(content) }
                    .foregroundStyle(.tertiary)
                headerButton("square.and.arrow.down", help: "Save as file") {
                    exportDocument = CodeFileDocument(text: content)
                    exportFilename = defaultFilename
                    showExporter = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            if isSVG && !showCode {
                SVGView(svg: content)
                    .padding(8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(Theme.Typography.font(.mono))
                        .textSelection(.enabled)
                        .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: CodeFileType.utType(for: language),
            defaultFilename: exportFilename
        ) { _ in }
    }

    /// E.g. "csv-20260716-1432"; the exporter appends the extension from the
    /// content type. Computed at tap time, not per render.
    private var defaultFilename: String {
        let stamp = Date.now.formatted(
            .verbatim(
                "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)",
                timeZone: .current, calendar: .current
            )
        )
        let prefix = language?.lowercased() ?? ""
        return "\(prefix.isEmpty ? "code" : prefix)-\(stamp)"
    }

    private func headerButton(
        _ systemImage: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help(help)
        // Icon-only button: .help is no VoiceOver label.
        .accessibilityLabel(Text(help))
    }
}
