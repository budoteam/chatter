import XCTest
import SwiftData
@testable import Chatter

/// Dispatch round-trips and prompt injection for the self-managed memory.
@MainActor
final class MemoryToolProviderTests: XCTestCase {
    // ModelContext does not retain its container; a local would deallocate on
    // return and the first insert would trap inside SwiftData.
    private var container: ModelContainer?
    private let provider = MemoryToolProvider()

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Agent.self, MemoryEntry.self,
            // In the hosted test process the `.automatic` default would hook
            // the in-memory store into the app's CloudKit mirroring (crash on
            // save: "No eligible connection available").
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        self.container = container
        return container.mainContext
    }

    private func save(_ content: String, agentID: UUID, context: ModelContext) throws -> String {
        try provider.call(
            namespacedName: MemoryToolProvider.saveToolName,
            argumentsJSON: #"{"content": "\#(content)"}"#,
            agentID: agentID, context: context
        )
    }

    func testSaveRoundTrip() throws {
        let context = try makeContext()
        let agentID = UUID()

        let result = try save("User ist Vegetarier", agentID: agentID, context: context)

        let entries = try context.fetch(FetchDescriptor<MemoryEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].agentID, agentID)
        XCTAssertEqual(entries[0].content, "User ist Vegetarier")
        XCTAssertEqual(result, "Saved memory [\(entries[0].shortID)].")
    }

    func testSaveRejectsEmptyAndOversizedContent() throws {
        let context = try makeContext()
        let agentID = UUID()

        XCTAssertThrowsError(try save("   ", agentID: agentID, context: context))
        XCTAssertThrowsError(try save(
            String(repeating: "x", count: 2_001), agentID: agentID, context: context
        ))
        XCTAssertEqual(try context.fetch(FetchDescriptor<MemoryEntry>()).count, 0)
    }

    func testUpdateAndDeleteByShortIDPrefix() throws {
        let context = try makeContext()
        let agentID = UUID()
        _ = try save("Alter Fakt", agentID: agentID, context: context)
        let entry = try XCTUnwrap(context.fetch(FetchDescriptor<MemoryEntry>()).first)
        let prefix = String(entry.shortID.prefix(4))

        _ = try provider.call(
            namespacedName: MemoryToolProvider.updateToolName,
            argumentsJSON: #"{"id": "\#(prefix.uppercased())", "content": "Neuer Fakt"}"#,
            agentID: agentID, context: context
        )
        XCTAssertEqual(entry.content, "Neuer Fakt")

        _ = try provider.call(
            namespacedName: MemoryToolProvider.deleteToolName,
            argumentsJSON: #"{"id": "\#(prefix)"}"#,
            agentID: agentID, context: context
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<MemoryEntry>()).count, 0)
    }

    func testUpdateUnknownIDThrows() throws {
        let context = try makeContext()
        XCTAssertThrowsError(try provider.call(
            namespacedName: MemoryToolProvider.updateToolName,
            argumentsJSON: #"{"id": "deadbeef", "content": "x"}"#,
            agentID: UUID(), context: context
        ))
    }

    func testEntriesAreScopedPerAgent() throws {
        let context = try makeContext()
        let agentA = UUID()
        let agentB = UUID()
        _ = try save("Fakt von A", agentID: agentA, context: context)

        // B's prompt must not leak A's memory, and B can't touch A's entry.
        let sectionB = provider.systemPromptSection(agentID: agentB, context: context)
        XCTAssertTrue(sectionB.contains("currently empty"))
        XCTAssertFalse(sectionB.contains("Fakt von A"))

        let entry = try XCTUnwrap(context.fetch(FetchDescriptor<MemoryEntry>()).first)
        XCTAssertThrowsError(try provider.call(
            namespacedName: MemoryToolProvider.deleteToolName,
            argumentsJSON: #"{"id": "\#(entry.shortID)"}"#,
            agentID: agentB, context: context
        ))
    }

    func testPromptSectionListsEntriesAndInstructions() throws {
        let context = try makeContext()
        let agentID = UUID()
        _ = try save("User heisst Fabian", agentID: agentID, context: context)

        let section = provider.systemPromptSection(agentID: agentID, context: context)
        let entry = try XCTUnwrap(context.fetch(FetchDescriptor<MemoryEntry>()).first)
        XCTAssertTrue(section.contains("[\(entry.shortID)] User heisst Fabian"))
        XCTAssertTrue(section.contains(MemoryToolProvider.saveToolName))
    }

    func testPromptSectionHidesTailOverBudget() throws {
        let context = try makeContext()
        let agentID = UUID()
        for i in 0..<10 {
            let entry = MemoryEntry(agentID: agentID, content: "Fakt \(i) " + String(repeating: "y", count: 600))
            context.insert(entry)
        }
        try context.save()

        let section = provider.systemPromptSection(agentID: agentID, context: context)
        XCTAssertTrue(section.contains("not shown"), "over-budget marker missing")
        XCTAssertLessThan(section.count, 6_000)
    }

    func testSchemasParseAsObjects() {
        for tool in provider.tools() {
            guard case .object(let schema) = JSONValue.parse(tool.function.parameters.jsonString) else {
                return XCTFail("schema of \(tool.function.name) is not a JSON object")
            }
            XCTAssertEqual(schema["type"], .string("object"))
        }
    }
}
