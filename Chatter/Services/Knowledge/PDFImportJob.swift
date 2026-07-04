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
            skippedNoun: "PDF without extractable text"
        )
        phase = .running(current: 1, total: urls.count, fileName: urls[0].lastPathComponent)

        task = Task {
            var takenPaths = Set((bundle.concepts ?? []).map(\.path))
            var processed = 0

            for (index, url) in urls.enumerated() {
                if Task.isCancelled { break }
                let fileName = url.lastPathComponent
                phase = .running(current: index + 1, total: urls.count, fileName: fileName)

                guard let data = readData(from: url) else {
                    report.warnings.append("\(fileName): could not read the file")
                    continue
                }

                // PDFKit parsing is CPU-bound; keep it off the main actor.
                // PDFDocument isn't Sendable, so the detached task creates and
                // consumes it entirely and returns only the value type.
                let extracted = await Task.detached(priority: .userInitiated) {
                    PDFKnowledgeImporter.extract(from: data, fileName: fileName)
                }.value

                guard let pdf = extracted else {
                    report.warnings.append("\(fileName): not a readable PDF")
                    continue
                }
                guard pdf.hasTextLayer else {
                    report.skipped += 1
                    report.warnings.append(
                        "\(fileName): no extractable text (scanned PDF?) — OCR is not supported yet"
                    )
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
                processed += 1
            }

            if Task.isCancelled, processed < urls.count {
                report.warnings.insert(
                    "Import cancelled after \(processed) of \(urls.count) PDFs.", at: 0
                )
            }
            phase = .finished
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Conversion

    /// LLM-refined conversion with the mechanical fallback rules:
    /// no model → fallback; a failed chunk → warning (other chunks survive);
    /// all chunks failed → fallback. Returns nil when the run was cancelled
    /// mid-conversion (no fallback in that case).
    private func convert(
        pdf: PDFKnowledgeImporter.ExtractedPDF,
        ollama: OllamaServiceProtocol,
        model: String?
    ) async -> [PDFKnowledgeImporter.LLMConcept]? {
        guard let model, !model.isEmpty else {
            report.warnings.append(
                "\(pdf.fileName): imported without AI conversion (no API key or model)"
            )
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
        var failures = 0
        for (index, chunk) in chunks.enumerated() {
            do {
                let response = try await completeChat(
                    ollama: ollama, model: model,
                    messages: PDFKnowledgeImporter.conversionMessages(
                        pdf: pdf, chunk: chunk, chunkIndex: index, chunkCount: chunks.count
                    )
                )
                if let parsed = PDFKnowledgeImporter.parseConcepts(from: response) {
                    concepts += parsed
                } else {
                    failures += 1
                    report.warnings.append(
                        "\(pdf.fileName): AI returned an unusable response for part \(index + 1) of \(chunks.count)"
                    )
                }
            } catch is CancellationError {
                return nil
            } catch {
                if Task.isCancelled { return nil }
                failures += 1
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
        if failures > 0 {
            report.warnings.append(
                "\(pdf.fileName): \(failures) of \(chunks.count) parts failed; the imported concepts may be incomplete"
            )
        }
        return concepts
    }

    /// Collects the existing streaming API into one string — the protocol has
    /// no non-streaming call, and this keeps it (and its mocks) untouched.
    private func completeChat(
        ollama: OllamaServiceProtocol, model: String, messages: [OllamaChatMessage]
    ) async throws -> String {
        var text = ""
        for try await chunk in ollama.streamChat(
            model: model, messages: messages, tools: [], temperature: 0
        ) {
            if case .delta(let piece) = chunk { text += piece }
            // .thinking / .toolCalls / .done are irrelevant here.
        }
        return text
    }

    // MARK: - File access

    /// Reads the bytes while the security-scoped resource is open, so PDFKit
    /// never touches the URL after the scope closes.
    private func readData(from url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }
}
