import Foundation
import SwiftData

/// Runs one PDF → OKF import: per file, read the bytes under the security
/// scope, extract text off-main, convert via the LLM (or mechanically), and
/// insert the concepts. Observable so the UI can render progress; cancellable
/// between PDFs (completed PDFs stay saved).
@MainActor
@Observable
final class PDFImportJob {
    enum Phase: Equatable {
        case idle
        case running(current: Int, total: Int, fileName: String)
        case finished
    }

    private(set) var phase: Phase = .idle
    private(set) var report = KnowledgeTransfer.ImportReport()
    private var task: Task<Void, Never>?

    /// `model` nil → mechanical import for every PDF (no API key / no models).
    func start(
        urls: [URL],
        bundle: KnowledgeBundle,
        context: ModelContext,
        ollama: OllamaServiceProtocol,
        model: String?
    ) {
        guard case .idle = phase, !urls.isEmpty else { return }
        report = KnowledgeTransfer.ImportReport(
            bundleName: bundle.name,
            skippedNoun: (singular: "PDF without extractable text",
                          plural: "PDFs without extractable text")
        )
        if model == nil || model?.isEmpty == true {
            report.warnings.append("No AI model — PDFs were imported as raw text.")
        }
        phase = .running(current: 1, total: urls.count, fileName: urls[0].lastPathComponent)

        task = Task {
            var takenPaths = Set((bundle.concepts ?? []).map(\.path))
            var handled = 0

            for (index, url) in urls.enumerated() {
                if Task.isCancelled { break }
                let fileName = url.lastPathComponent
                phase = .running(current: index + 1, total: urls.count, fileName: fileName)

                // Reading the bytes and parsing are both off the main actor:
                // the security scope is process-wide and URL is Sendable, so
                // a big/iCloud PDF never blocks the UI. PDFDocument isn't
                // Sendable, so it's created and consumed inside the closure,
                // returning only the value-type ExtractedPDF.
                let outcome = await Task.detached(priority: .userInitiated) {
                    guard let data = Self.readData(from: url) else { return ExtractResult.unreadable }
                    guard let pdf = PDFKnowledgeImporter.extract(from: data, fileName: fileName) else {
                        return ExtractResult.notAPDF
                    }
                    return .ok(pdf)
                }.value

                let pdf: PDFKnowledgeImporter.ExtractedPDF
                switch outcome {
                case .unreadable:
                    report.warnings.append("\(fileName): could not read the file")
                    handled += 1
                    continue
                case .notAPDF:
                    report.warnings.append("\(fileName): not a readable PDF")
                    handled += 1
                    continue
                case .ok(let extracted):
                    pdf = extracted
                }
                guard pdf.hasTextLayer else {
                    report.skipped += 1
                    report.warnings.append(
                        "\(fileName): no extractable text (scanned PDF?) — OCR is not supported yet"
                    )
                    handled += 1
                    continue
                }

                // nil → the run was cancelled mid-conversion.
                guard let concepts = await convert(pdf: pdf, ollama: ollama, model: model) else {
                    break
                }

                PDFKnowledgeImporter.insert(
                    concepts,
                    pdfSlug: PDFKnowledgeImporter.slug(from: pdf.baseName),
                    from: pdf,
                    into: bundle, context: context,
                    takenPaths: &takenPaths, report: &report
                )
                // Save per PDF so cancellation keeps completed documents.
                bundle.updatedAt = .now
                try? context.save()
                handled += 1
            }

            // handled counts every fully-processed file (imported, skipped, or
            // unreadable); only warn about a cancellation that left files out.
            if handled < urls.count {
                report.warnings.insert(
                    "Import cancelled after \(handled) of \(urls.count) PDFs.", at: 0
                )
            }
            phase = .finished
        }
    }

    /// Result of the off-main read+extract step (all Sendable value types).
    private enum ExtractResult {
        case unreadable
        case notAPDF
        case ok(PDFKnowledgeImporter.ExtractedPDF)
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Conversion

    /// LLM-refined conversion with the mechanical fallback rules:
    /// no model → fallback (warned once, run-level, in `start`); a failed
    /// chunk → warning (other chunks survive); all chunks failed → fallback.
    /// Returns nil when the run was cancelled mid-conversion (no fallback).
    private func convert(
        pdf: PDFKnowledgeImporter.ExtractedPDF,
        ollama: OllamaServiceProtocol,
        model: String?
    ) async -> [PDFKnowledgeImporter.LLMConcept]? {
        guard let model, !model.isEmpty else {
            return [PDFKnowledgeImporter.fallbackConcept(for: pdf)]
        }

        var chunks = PDFKnowledgeImporter.splitIntoChunks(
            pdf.text, maxChars: PDFKnowledgeImporter.chunkMaxChars
        )
        if chunks.count > PDFKnowledgeImporter.maxChunksPerPDF {
            chunks = Array(chunks.prefix(PDFKnowledgeImporter.maxChunksPerPDF))
            report.warnings.append(
                "\(pdf.fileName): very large PDF — only the first "
                    + "~\(PDFKnowledgeImporter.chunkMaxChars * PDFKnowledgeImporter.maxChunksPerPDF) "
                    + "characters were converted"
            )
        }

        var concepts: [PDFKnowledgeImporter.LLMConcept] = []
        for (index, chunk) in chunks.enumerated() {
            do {
                let response = try await ollama.complete(
                    model: model,
                    messages: PDFKnowledgeImporter.conversionMessages(
                        pdf: pdf, chunk: chunk, chunkIndex: index, chunkCount: chunks.count
                    )
                )
                // The stream ends silently (no throw) on cancellation, so the
                // response may be partial — check explicitly.
                if Task.isCancelled { return nil }
                if let parsed = PDFKnowledgeImporter.parseConcepts(from: response) {
                    concepts += parsed
                } else {
                    report.warnings.append(
                        "\(pdf.fileName): AI returned an unusable response for part \(index + 1) of \(chunks.count)"
                    )
                }
            } catch is CancellationError {
                return nil
            } catch {
                if Task.isCancelled { return nil }
                report.warnings.append(
                    "\(pdf.fileName): AI conversion failed for part \(index + 1) of \(chunks.count) "
                        + "(\(error.localizedDescription))"
                )
            }
        }

        if concepts.isEmpty {
            report.warnings.append("\(pdf.fileName): AI conversion failed — imported raw text instead")
            return [PDFKnowledgeImporter.fallbackConcept(for: pdf)]
        }
        return concepts
    }

    // MARK: - File access

    /// Reads the bytes while the security-scoped resource is open, so PDFKit
    /// never touches the URL after the scope closes. Static + nonisolated so
    /// it can run inside the off-main extraction task.
    nonisolated static func readData(from url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }
}
