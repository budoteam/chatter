import XCTest
import SwiftData
@testable import Chatter

/// Tests for the pure parts of the PDF → OKF pipeline: slugs, path dedupe,
/// chunking, LLM-JSON parsing, fallback, and SwiftData insertion. PDFKit
/// extraction itself needs real PDF fixtures and is covered by manual testing.
final class PDFKnowledgeImporterTests: XCTestCase {

    // MARK: - slug(from:)

    func testSlugSanitizesNames() {
        XCTAssertEqual(PDFKnowledgeImporter.slug(from: "My Händbook 2026"), "my-handbook-2026")
        XCTAssertEqual(PDFKnowledgeImporter.slug(from: "Ops // Runbook!!"), "ops-runbook")
        XCTAssertEqual(PDFKnowledgeImporter.slug(from: "  --Weird__Name--  "), "weird-name")
        XCTAssertEqual(PDFKnowledgeImporter.slug(from: "§±≠"), "pdf")
        XCTAssertEqual(PDFKnowledgeImporter.slug(from: ""), "pdf")
    }

    func testSlugIsCapped() {
        let long = String(repeating: "a", count: 200)
        XCTAssertLessThanOrEqual(PDFKnowledgeImporter.slug(from: long).count, 64)
    }

    // MARK: - uniquePath

    func testUniquePathCountsUpOnCollision() {
        let taken: Set<String> = ["doc/intro", "doc/intro-2"]
        XCTAssertEqual(PDFKnowledgeImporter.uniquePath("doc/intro", taken: taken), "doc/intro-3")
        XCTAssertEqual(PDFKnowledgeImporter.uniquePath("doc/fresh", taken: taken), "doc/fresh")
    }

    func testUniquePathAvoidsReservedNames() {
        XCTAssertEqual(PDFKnowledgeImporter.uniquePath("doc/index", taken: []), "doc/index-doc")
        XCTAssertEqual(PDFKnowledgeImporter.uniquePath("doc/log", taken: []), "doc/log-doc")
        XCTAssertEqual(
            PDFKnowledgeImporter.uniquePath("doc/index", taken: ["doc/index-doc"]),
            "doc/index-doc-2"
        )
    }

    // MARK: - splitIntoChunks

    func testShortTextIsOneChunk() {
        let chunks = PDFKnowledgeImporter.splitIntoChunks("hello\n\nworld", maxChars: 100)
        XCTAssertEqual(chunks, ["hello\n\nworld"])
    }

    func testSplitsAtParagraphBoundaries() {
        let a = String(repeating: "a", count: 60)
        let b = String(repeating: "b", count: 60)
        let c = String(repeating: "c", count: 60)
        let chunks = PDFKnowledgeImporter.splitIntoChunks([a, b, c].joined(separator: "\n\n"), maxChars: 130)
        XCTAssertEqual(chunks, [a + "\n\n" + b, c])
    }

    func testOversizedParagraphIsHardSplit() {
        let long = String(repeating: "x", count: 250)
        let chunks = PDFKnowledgeImporter.splitIntoChunks("intro\n\n" + long, maxChars: 100)
        XCTAssertEqual(chunks.first, "intro")
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 100 })
        XCTAssertEqual(chunks.joined().count, "intro".count + 250)
    }

    func testChunkingPreservesAllContent() {
        let paragraphs = (1...40).map { "Paragraph \($0) with some content." }
        let text = paragraphs.joined(separator: "\n\n")
        let chunks = PDFKnowledgeImporter.splitIntoChunks(text, maxChars: 200)
        let rejoined = chunks.joined(separator: "\n\n")
        for paragraph in paragraphs {
            XCTAssertTrue(rejoined.contains(paragraph))
        }
    }

    // MARK: - parseConcepts

    private let validJSON = """
    {"concepts":[{"slug":"ch-1","type":"guide","title":"Chapter 1",\
    "description":"First chapter","tags":["intro"],"markdown":"# Chapter 1\\nText."}]}
    """

    func testParsesCleanJSON() {
        let concepts = PDFKnowledgeImporter.parseConcepts(from: validJSON)
        XCTAssertEqual(concepts?.count, 1)
        XCTAssertEqual(concepts?.first?.slug, "ch-1")
        XCTAssertEqual(concepts?.first?.tags, ["intro"])
    }

    func testParsesJSONWrappedInFencesAndProse() {
        let raw = "Sure! Here is the JSON:\n```json\n\(validJSON)\n```\nHope that helps."
        XCTAssertEqual(PDFKnowledgeImporter.parseConcepts(from: raw)?.count, 1)
    }

    func testParsesJSONAfterThinkBlock() {
        let raw = "<think>\nLet me split this…\n</think>\n\(validJSON)"
        XCTAssertEqual(PDFKnowledgeImporter.parseConcepts(from: raw)?.count, 1)
    }

    func testMissingOptionalFieldsDecode() {
        let raw = #"{"concepts":[{"slug":"a","title":"A","markdown":"Body"}]}"#
        let concept = PDFKnowledgeImporter.parseConcepts(from: raw)?.first
        XCTAssertNotNil(concept)
        XCTAssertNil(concept?.type)
        XCTAssertNil(concept?.tags)
        XCTAssertNil(concept?.description)
    }

    func testMalformedAndEmptyPayloadsReturnNil() {
        XCTAssertNil(PDFKnowledgeImporter.parseConcepts(from: "not json at all"))
        XCTAssertNil(PDFKnowledgeImporter.parseConcepts(from: #"{"concepts":[]}"#))
        XCTAssertNil(PDFKnowledgeImporter.parseConcepts(
            from: #"{"concepts":[{"slug":"a","title":"","markdown":""}]}"#
        ))
    }

    // MARK: - fallbackConcept

    func testFallbackUsesMetadataTitleThenFileName() {
        var pdf = PDFKnowledgeImporter.ExtractedPDF(
            fileName: "Handbook.pdf", text: "Raw text.", title: "Employee Handbook",
            creationDate: nil, pageCount: 3
        )
        XCTAssertEqual(PDFKnowledgeImporter.fallbackConcept(for: pdf).title, "Employee Handbook")
        pdf.title = nil
        let fallback = PDFKnowledgeImporter.fallbackConcept(for: pdf)
        XCTAssertEqual(fallback.title, "Handbook")
        XCTAssertEqual(fallback.slug, "full-text")
        XCTAssertEqual(fallback.markdown, "Raw text.")
    }

    // MARK: - insert

    @MainActor
    func testInsertCreatesConceptsUnderPDFFolder() throws {
        let container = try ModelContainer(
            for: KnowledgeBundle.self, KnowledgeConcept.self,
            // In the hosted test process the `.automatic` default would hook
            // the in-memory store into the app's CloudKit mirroring (crash on
            // save: "No eligible connection available").
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = container.mainContext
        let bundle = KnowledgeBundle(name: "Docs")
        context.insert(bundle)
        let existing = KnowledgeConcept(path: "handbook/intro")
        existing.bundle = bundle
        context.insert(existing)

        let pdf = PDFKnowledgeImporter.ExtractedPDF(
            fileName: "Handbook.pdf", text: "…", title: nil, creationDate: nil, pageCount: 5
        )
        let concepts = [
            PDFKnowledgeImporter.LLMConcept(
                slug: "Intro!", type: " guide ", title: "Intro",
                description: "The intro", tags: ["a"], markdown: "# Intro"
            ),
            PDFKnowledgeImporter.LLMConcept(
                slug: "big", type: nil, title: "Big",
                description: nil, tags: nil,
                markdown: String(repeating: "y", count: PDFKnowledgeImporter.conceptMarkdownCap + 50)
            ),
        ]
        var taken = Set((bundle.concepts ?? []).map(\.path))
        var report = KnowledgeTransfer.ImportReport(bundleName: "Docs")
        PDFKnowledgeImporter.insert(
            concepts, pdfSlug: "handbook", from: pdf,
            into: bundle, context: context, takenPaths: &taken, report: &report
        )

        XCTAssertEqual(report.imported, 2)
        // "Intro!" sanitizes to "intro", collides with the pre-existing path.
        let intro = bundle.concept(atPath: "handbook/intro-2")
        XCTAssertNotNil(intro)
        XCTAssertEqual(intro?.typeName, "guide")
        // Provenance is the plain source file name, not a fabricated file:// URI.
        XCTAssertEqual(intro?.resource, "Handbook.pdf")

        let big = bundle.concept(atPath: "handbook/big")
        XCTAssertNotNil(big)
        XCTAssertEqual(big?.typeName, "note")
        XCTAssertLessThanOrEqual(big?.body.count ?? 0, PDFKnowledgeImporter.conceptMarkdownCap + 40)
        XCTAssertEqual(report.warnings.count, 1)
    }
}
