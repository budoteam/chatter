import Foundation
import PDFKit
import SwiftData

/// Turns PDFs into OKF knowledge concepts: PDFKit text extraction, an
/// LLM contract that structures the text into clean concepts, and the
/// mechanical fallback used when no model is available. Everything except
/// `insert` is pure/stateless so the pipeline is unit-testable without
/// fixtures or network.
enum PDFKnowledgeImporter {

    // MARK: - Tunables

    /// Extracted text per LLM request; long PDFs are converted chunk-wise.
    static let chunkMaxChars = 20_000
    /// Hard cap per PDF (~120k chars); the rest is truncated with a warning.
    static let maxChunksPerPDF = 6
    /// Per-concept body cap, derived from the read tool's limit (with margin)
    /// so a concept never gets truncated a second time at read time.
    static let conceptMarkdownCap = KnowledgeToolProvider.readCharacterLimit - 4_000
    /// Extracted text shorter than this counts as "no text layer" (scan).
    static let minimumTextLength = 20

    // MARK: - Extraction (PDFKit, no OCR)

    struct ExtractedPDF: Sendable {
        var fileName: String
        /// All pages joined with blank lines, trimmed.
        var text: String
        var title: String?
        var creationDate: Date?
        var pageCount: Int

        /// True when the PDF has no usable text layer (scanned images).
        var hasTextLayer: Bool { text.count >= PDFKnowledgeImporter.minimumTextLength }

        var baseName: String { (fileName as NSString).deletingPathExtension }
    }

    /// Builds the document from `Data` on purpose: the caller reads the bytes
    /// while the security-scoped resource is still open, so PDFKit's lazy
    /// page loading can't race the scope's lifetime. Returns nil for data
    /// PDFKit can't open at all.
    static func extract(from data: Data, fileName: String) -> ExtractedPDF? {
        guard let document = PDFDocument(data: data) else { return nil }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            if let text = document.page(at: index)?.string {
                pages.append(text)
            }
        }
        let attributes = document.documentAttributes
        let rawTitle = (attributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespaces)
        return ExtractedPDF(
            fileName: fileName,
            text: pages.joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            title: (rawTitle?.isEmpty == false) ? rawTitle : nil,
            creationDate: attributes?[PDFDocumentAttribute.creationDateAttribute] as? Date,
            pageCount: document.pageCount
        )
    }

    // MARK: - LLM contract

    /// One concept as the model returns it. Only `slug`, `title`, and
    /// `markdown` are required; the rest degrades gracefully.
    struct LLMConcept: Codable {
        var slug: String
        var type: String?
        var title: String
        var description: String?
        var tags: [String]?
        var markdown: String
    }

    struct LLMPayload: Codable {
        var concepts: [LLMConcept]
    }

    private static let conversionSystemPrompt = """
    You convert text extracted from a PDF into knowledge-base concept documents.
    Respond with STRICT JSON only. No markdown code fences, no commentary, no \
    text before or after the JSON object.

    Schema:
    {"concepts":[{"slug":"kebab-case-id","type":"note","title":"Human title",\
    "description":"One-sentence summary","tags":["tag1","tag2"],\
    "markdown":"# Cleaned markdown body"}]}

    Rules:
    - Split the document into 1-8 coherent concepts by theme or chapter. \
    Prefer fewer, substantial concepts over many fragments.
    - "markdown": well-structured markdown (headings, lists, paragraphs). \
    Repair PDF artifacts: broken line wraps, hyphenation splits, running \
    headers/footers, page numbers. Preserve the substance — reorganize and \
    clean, do not summarize content away.
    - Keep each concept's markdown under 10000 characters.
    - "slug": lowercase letters, digits, hyphens only.
    - "type": a short noun like note, guide, reference, article, spec.
    - Write in the document's own language.
    """

    static func conversionMessages(
        pdf: ExtractedPDF, chunk: String, chunkIndex: Int, chunkCount: Int
    ) -> [OllamaChatMessage] {
        var user = "PDF file: \(pdf.fileName)\n"
        if let title = pdf.title {
            user += "PDF title: \(title)\n"
        }
        if chunkCount > 1 {
            user += "Part \(chunkIndex + 1) of \(chunkCount) of the extracted text "
                + "(concepts from other parts are generated separately — cover only "
                + "this part, do not reference the others).\n"
        }
        user += "\n" + chunk
        return [
            OllamaChatMessage(role: "system", content: conversionSystemPrompt),
            OllamaChatMessage(role: "user", content: user),
        ]
    }

    /// Extracts and decodes the model's JSON payload. Tolerates a leaked
    /// `<think>` block, code fences, and prose around the object by taking
    /// the substring from the first `{` to the last `}`. nil → the caller
    /// falls back to the mechanical import.
    static func parseConcepts(from raw: String) -> [LLMConcept]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<think>"), let end = text.range(of: "</think>") {
            text = String(text[end.upperBound...])
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(LLMPayload.self, from: data)
        else { return nil }

        let concepts = payload.concepts.filter {
            !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return concepts.isEmpty ? nil : concepts
    }

    // MARK: - Mechanical fallback

    /// Used when no model is available or the LLM output was unusable:
    /// the whole PDF becomes one raw-text concept at `<pdf-slug>/full-text`.
    static func fallbackConcept(for pdf: ExtractedPDF) -> LLMConcept {
        LLMConcept(
            slug: "full-text",
            type: "document",
            title: pdf.title ?? pdf.baseName,
            description: "Raw text extracted from \(pdf.fileName) "
                + "(\(pdf.pageCount) page\(pdf.pageCount == 1 ? "" : "s")).",
            tags: [],
            markdown: pdf.text
        )
    }

    // MARK: - Pure helpers

    /// Sanitizes any name (file names, model-provided slugs — never trust the
    /// latter verbatim) into a lowercase ASCII kebab-case slug, capped at 64.
    static func slug(from name: String) -> String {
        let folded = name.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        var lastWasDash = true  // swallows leading separators
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
            if result.count >= 64 { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "pdf" : result
    }

    /// Resolves collisions with the `x`, `x-2`, `x-3`… scheme and keeps
    /// generated paths off the reserved OKF filenames — reusing the single
    /// reserved-name rule so new reserved names are picked up automatically.
    static func uniquePath(_ desired: String, taken: Set<String>) -> String {
        var base = desired
        let lastComponent = base.split(separator: "/").last.map(String.init) ?? base
        if KnowledgeDocKind.forFileName(lastComponent + ".md") != .concept {
            base += "-doc"
        }
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }

    /// Splits text into chunks of at most `maxChars`, preferring paragraph
    /// boundaries; paragraphs longer than the limit are hard-split. No input
    /// text is lost (blank-line runs between paragraphs may collapse). Runs in
    /// a single linear pass: sizes are tracked with `Int` counters and long
    /// paragraphs are sliced by index rather than repeatedly re-counted/copied.
    static func splitIntoChunks(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        // Break oversized paragraphs into ≤ maxChars pieces first, by index.
        var pieces: [Substring] = []
        for paragraph in text.components(separatedBy: "\n\n") {
            var start = paragraph.startIndex
            while start < paragraph.endIndex {
                let end = paragraph.index(start, offsetBy: maxChars, limitedBy: paragraph.endIndex)
                    ?? paragraph.endIndex
                pieces.append(paragraph[start..<end])
                start = end
            }
        }

        // Greedily pack pieces (all ≤ maxChars) using running Int sizes.
        var chunks: [String] = []
        var current = ""
        var currentCount = 0
        for piece in pieces {
            let pieceCount = piece.count
            if pieceCount == 0 { continue }
            let separator = current.isEmpty ? 0 : 2  // "\n\n"
            if currentCount + separator + pieceCount > maxChars, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentCount = 0
            }
            if current.isEmpty {
                current = String(piece)
                currentCount = pieceCount
            } else {
                current += "\n\n" + piece
                currentCount += 2 + pieceCount
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - SwiftData insertion

    /// Inserts converted concepts under `<pdfSlug>/…`, mirroring the folder
    /// import's pattern (path dedupe, insert, report bookkeeping). The caller
    /// bumps `bundle.updatedAt` and saves — once per PDF, so cancellation
    /// keeps completed documents.
    @MainActor
    static func insert(
        _ concepts: [LLMConcept],
        pdfSlug: String,
        from pdf: ExtractedPDF,
        into bundle: KnowledgeBundle,
        context: ModelContext,
        takenPaths: inout Set<String>,
        report: inout KnowledgeTransfer.ImportReport
    ) {
        for llm in concepts {
            let path = uniquePath("\(pdfSlug)/\(slug(from: llm.slug))", taken: takenPaths)
            takenPaths.insert(path)

            let concept = KnowledgeConcept(path: path)
            concept.bundle = bundle
            context.insert(concept)

            let type = llm.type?.trimmingCharacters(in: .whitespaces)
            concept.typeName = (type?.isEmpty == false) ? type! : "note"
            concept.title = llm.title
            concept.summary = llm.description
            concept.tags = llm.tags ?? []
            concept.timestampRaw = KnowledgeConcept.currentTimestampString()
            // Provenance: the source file name (a plain name, not a fabricated
            // file:// URI that wouldn't be a valid resource URI).
            concept.resource = pdf.fileName

            var body = llm.markdown
            if body.count > conceptMarkdownCap {
                body = String(body.prefix(conceptMarkdownCap)) + "\n\n… [truncated on import]"
                report.warnings.append(
                    "\(pdf.fileName): concept “\(path)” exceeded \(conceptMarkdownCap) characters and was truncated"
                )
            }
            concept.body = body
            report.imported += 1
        }
    }
}
