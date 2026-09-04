import Foundation
import PDFKit
import Vision

/// Turns a picked PDF into a `DocumentDraft` for the chat composer: text-layer
/// extraction via `PDFKnowledgeImporter` (PDFKit), and for scanned PDFs
/// without a text layer an on-device Vision OCR fallback. Pure/stateless —
/// call off the main thread for large documents (OCR is CPU-bound).
enum PDFAttachmentProcessor {

    // MARK: - Tunables

    /// Scans are OCRed up to this many pages (rendering + recognition is the
    /// slow path); beyond that the recognized text is simply truncated.
    static let maxOCRPages = 20
    /// Render scale for OCR page bitmaps (PDF points → pixels). 2× is enough
    /// for accurate recognition without exploding memory on dense pages.
    static let ocrRenderScale: CGFloat = 2.0

    // MARK: - Draft building

    /// Returns nil when the data is no readable PDF or yields no text at all
    /// (corrupt file, image-only scan that OCR couldn't read either).
    static func makeDraft(from data: Data, fileName: String) -> DocumentDraft? {
        guard let pdf = PDFKnowledgeImporter.extract(from: data, fileName: fileName)
        else { return nil }

        var text = pdf.text
        var usedOCR = false
        if !pdf.hasTextLayer {
            usedOCR = true
            text = ocrText(from: data, pageCount: pdf.pageCount)
        }

        var truncated = false
        let cap = DocumentAttachment.maxCharactersPerDocument
        if text.count > cap {
            text = String(text.prefix(cap)) + "\n\n… [truncated]"
            truncated = true
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return DocumentDraft(
            attachment: DocumentAttachment(
                fileName: fileName,
                pageCount: pdf.pageCount,
                usedOCR: usedOCR,
                truncated: truncated
            ),
            text: text
        )
    }

    // MARK: - OCR fallback (Vision)

    /// Renders pages to bitmaps and recognizes their text on-device. Pages
    /// past `maxOCRPages` are skipped.
    static func ocrText(from data: Data, pageCount: Int) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        var pages: [String] = []
        for index in 0..<min(pageCount, maxOCRPages) {
            guard let page = document.page(at: index),
                  let image = renderPage(page) else { continue }
            let text = recognizeText(in: image)
            if !text.isEmpty { pages.append(text) }
        }
        return pages.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Synchronous Vision text recognition — the caller decides the thread.
    static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // The app's user base is German-first; English covers most technical
        // documents. Vision falls back gracefully for other languages.
        request.recognitionLanguages = ["de-DE", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// Renders one PDF page to a white-backed bitmap at `ocrRenderScale`.
    static func renderPage(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int((bounds.width * ocrRenderScale).rounded(.up))
        let height = Int((bounds.height * ocrRenderScale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        // Scans often have transparent backgrounds; OCR needs contrast.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: ocrRenderScale, y: ocrRenderScale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
