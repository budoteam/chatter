import XCTest
import SwiftData
@testable import Chatter

/// Model-mapping round trips: OKF file → `KnowledgeConcept` → OKF file.
@MainActor
final class KnowledgeTransferTests: XCTestCase {
    // ModelContext does not retain its container; a local would deallocate on
    // return and the first insert would trap inside SwiftData.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: KnowledgeBundle.self, KnowledgeConcept.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        self.container = container
        return container.mainContext
    }

    func testImportReportPluralizesTheRightWord() {
        var report = KnowledgeTransfer.ImportReport(
            bundleName: "Docs",
            skippedNoun: (singular: "PDF without extractable text",
                          plural: "PDFs without extractable text")
        )
        report.imported = 1
        report.skipped = 2
        XCTAssertEqual(
            report.summary,
            "Imported 1 document into “Docs”. Skipped 2 PDFs without extractable text."
        )

        report.imported = 3
        report.skipped = 1
        XCTAssertEqual(
            report.summary,
            "Imported 3 documents into “Docs”. Skipped 1 PDF without extractable text."
        )
    }

    func testDefaultImportReportSkipNounUnchanged() {
        var report = KnowledgeTransfer.ImportReport(bundleName: "B")
        report.imported = 2
        report.skipped = 2
        XCTAssertEqual(report.summary, "Imported 2 documents into “B”. Skipped 2 non-markdown files.")
    }

    func testConceptFileRoundTripsThroughTheModel() throws {
        let context = try makeContext()
        let bundle = KnowledgeBundle(name: "Test")
        context.insert(bundle)

        let source = """
        ---
        type: playbook
        title: Rollback
        tags: [ops]
        custom_key: kept verbatim
        ---

        1. Do the thing.

        """
        let doc = OKFCodec.parse(path: "ops/rollback.md", contents: source)
        let concept = KnowledgeConcept(path: "ops/rollback")
        concept.bundle = bundle
        context.insert(concept)
        KnowledgeTransfer.apply(doc, to: concept)

        XCTAssertEqual(concept.typeName, "playbook")
        XCTAssertEqual(concept.tags, ["ops"])
        XCTAssertEqual(concept.extraFields.map(\.key), ["custom_key"])
        XCTAssertEqual(KnowledgeTransfer.serializedContents(for: concept), source)
    }

    func testReservedFileRoundTripsThroughTheModel() throws {
        let context = try makeContext()
        let bundle = KnowledgeBundle(name: "Test")
        context.insert(bundle)

        let source = "# Index\n\n* [Rollback](/ops/rollback.md) - how to roll back\n"
        let doc = OKFCodec.parse(path: "index.md", contents: source)
        let concept = KnowledgeConcept(path: "index")
        concept.bundle = bundle
        context.insert(concept)
        KnowledgeTransfer.apply(doc, to: concept)

        XCTAssertEqual(concept.kind, .index)
        XCTAssertEqual(KnowledgeTransfer.serializedContents(for: concept), source)
    }

    func testGeneratedRootIndexListsConceptsBySection() throws {
        let context = try makeContext()
        let bundle = KnowledgeBundle(name: "Data")
        context.insert(bundle)
        for (path, title) in [("tables/users", "Users"), ("tables/orders", "Orders"), ("readme-ish", nil)] {
            let concept = KnowledgeConcept(path: path, title: title)
            concept.bundle = bundle
            context.insert(concept)
        }

        let index = KnowledgeTransfer.generatedRootIndex(for: bundle)
        XCTAssertTrue(index.hasPrefix("# Data\n"))
        XCTAssertTrue(index.contains("## tables"))
        XCTAssertTrue(index.contains("* [Users](/tables/users.md)"))
        XCTAssertTrue(index.contains("## Concepts"))
    }
}
