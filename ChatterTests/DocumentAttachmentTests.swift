import XCTest
import CoreText
@testable import Chatter

/// PDF chat attachments: JSON round-trip of the metadata, the prompt format
/// that embeds extracted text into `Message.content`, and the extraction
/// pipeline itself (text layer via PDFKit; OCR is covered manually since it
/// needs image fixtures and is inherently fuzzy).
final class DocumentAttachmentTests: XCTestCase {

    // MARK: - Message.documentAttachments round-trip

    func testDocumentAttachmentsRoundTrip() {
        let message = Message(role: .user, content: "hi")
        XCTAssertTrue(message.documentAttachments.isEmpty)
        XCTAssertNil(message.documentsJSON)

        let documents = [
            DocumentAttachment(fileName: "a.pdf", pageCount: 3),
            DocumentAttachment(fileName: "scan.pdf", pageCount: 12, usedOCR: true, truncated: true),
        ]
        message.documentAttachments = documents
        XCTAssertEqual(message.documentAttachments, documents)

        message.documentAttachments = []
        XCTAssertNil(message.documentsJSON)
    }

    // MARK: - DocumentPromptFormat

    func testComposeAppendsDocumentBlocks() {
        let draft = DocumentDraft(
            attachment: DocumentAttachment(fileName: "report.pdf", pageCount: 2),
            text: "Body text."
        )
        let content = DocumentPromptFormat.compose(text: "Summarize", documents: [draft])
        XCTAssertTrue(content.hasPrefix("Summarize"))
        XCTAssertTrue(content.contains("[Document: report.pdf — 2 pages]"))
        XCTAssertTrue(content.hasSuffix("Body text."))
    }

    func testComposeFlagsOCRAndTruncation() {
        let draft = DocumentDraft(
            attachment: DocumentAttachment(fileName: "scan.pdf", pageCount: 1, usedOCR: true, truncated: true),
            text: "x"
        )
        let content = DocumentPromptFormat.compose(text: "", documents: [draft])
        XCTAssertTrue(content.contains("[Document: scan.pdf — 1 page, OCR, truncated]"))
    }

    func testTypedContentStripsDocumentBlocks() {
        let drafts = [
            DocumentDraft(attachment: DocumentAttachment(fileName: "a.pdf", pageCount: 1), text: "A"),
            DocumentDraft(attachment: DocumentAttachment(fileName: "b.pdf", pageCount: 1), text: "B"),
        ]
        let message = Message(role: .user)
        message.content = DocumentPromptFormat.compose(text: "My question", documents: drafts)
        XCTAssertEqual(message.typedContent, "My question")

        let docOnly = Message(role: .user)
        docOnly.content = DocumentPromptFormat.compose(text: "", documents: drafts)
        XCTAssertEqual(docOnly.typedContent, "")

        let plain = Message(role: .user, content: "no attachments")
        XCTAssertEqual(plain.typedContent, "no attachments")
    }

    // MARK: - PDFAttachmentProcessor (text-layer path)

    func testMakeDraftExtractsTextLayer() throws {
        let data = Self.makeTextPDF(text: "Hello Chatter, this is a text-layer PDF document.")
        let draft = try XCTUnwrap(PDFAttachmentProcessor.makeDraft(from: data, fileName: "note.pdf"))
        XCTAssertEqual(draft.attachment.fileName, "note.pdf")
        XCTAssertEqual(draft.attachment.pageCount, 1)
        XCTAssertFalse(draft.attachment.usedOCR)
        XCTAssertFalse(draft.attachment.truncated)
        XCTAssertTrue(draft.text.contains("Hello Chatter"))
    }

    func testMakeDraftTruncatesOversizedText() throws {
        let long = String(repeating: "x", count: DocumentAttachment.maxCharactersPerDocument + 500)
        let data = Self.makeTextPDF(text: long)
        let draft = try XCTUnwrap(PDFAttachmentProcessor.makeDraft(from: data, fileName: "big.pdf"))
        XCTAssertTrue(draft.attachment.truncated, "extracted \(draft.text.count) chars, usedOCR=\(draft.attachment.usedOCR)")
        XCTAssertLessThanOrEqual(
            draft.text.count,
            DocumentAttachment.maxCharactersPerDocument + 20,
            "cap plus the truncation marker (got \(draft.text.count))"
        )
        XCTAssertTrue(draft.text.hasSuffix("[truncated]"))
    }

    func testMakeDraftRejectsNonPDF() {
        XCTAssertNil(PDFAttachmentProcessor.makeDraft(from: Data("not a pdf".utf8), fileName: "x.pdf"))
    }

    /// Minimal PDF with a real text layer, drawn line-by-line via CoreText
    /// (a single enormous line gets clipped by PDFKit's extraction) so it
    /// works identically on the iOS and macOS test hosts.
    private static func makeTextPDF(text: String) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return Data() }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let lineHeight: CGFloat = 16
        let top: CGFloat = 740
        let bottom: CGFloat = 40
        // Wrap into fixed-width lines (content is irrelevant, volume matters).
        var lines: [Substring] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 72, limitedBy: text.endIndex) ?? text.endIndex
            lines.append(text[index..<end])
            index = end
        }
        context.beginPDFPage(nil)
        var y = top
        for line in lines {
            if y < bottom {
                context.endPDFPage()
                context.beginPDFPage(nil)
                y = top
            }
            let attributed = NSAttributedString(string: String(line), attributes: [.font: font])
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            y -= lineHeight
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
