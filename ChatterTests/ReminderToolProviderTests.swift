import XCTest
import SwiftData
@testable import Chatter

/// Dispatch round-trips and prompt injection for the reminder tools.
/// Notification scheduling is stubbed out — UNUserNotificationCenter is not
/// meaningful in the hosted test runner.
@MainActor
final class ReminderToolProviderTests: XCTestCase {
    // ModelContext does not retain its container; a local would deallocate on
    // return and the first insert would trap inside SwiftData.
    private var container: ModelContainer?
    private let provider = ReminderToolProvider()
    private var scheduled: [ReminderEntry] = []
    private var cancelled: [UUID] = []

    override func setUp() {
        super.setUp()
        scheduled = []
        cancelled = []
        provider.scheduleNotification = { [weak self] in
            self?.scheduled.append($0)
            return true
        }
        provider.cancelNotification = { [weak self] in self?.cancelled.append($0) }
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Agent.self, ReminderEntry.self,
            // In the hosted test process the `.automatic` default would hook
            // the in-memory store into the app's CloudKit mirroring (crash on
            // save: "No eligible connection available").
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        self.container = container
        return container.mainContext
    }

    /// A due date comfortably in the future, as ISO 8601 with timezone.
    private func futureDue() -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))
    }

    private func create(
        _ content: String,
        due: String? = nil,
        action: String? = nil,
        agentID: UUID,
        context: ModelContext
    ) async throws -> String {
        var json = #"{"content": "\#(content)", "due": "\#(due ?? futureDue())""#
        if let action { json += #", "action": "\#(action)""# }
        json += "}"
        return try await provider.call(
            namespacedName: ReminderToolProvider.createToolName,
            argumentsJSON: json,
            agentID: agentID, context: context
        )
    }

    /// XCTAssertThrowsError can't await; this is the async equivalent.
    private func assertThrowsToolError(
        _ expected: ReminderToolProvider.ToolError,
        _ expression: () async throws -> String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected \(expected), but the call succeeded", file: file, line: line)
        } catch let error as ReminderToolProvider.ToolError {
            XCTAssertEqual(error.localizedDescription, expected.localizedDescription, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    func testCreateRoundTripSchedulesNotification() async throws {
        let context = try makeContext()
        let agentID = UUID()

        let result = try await create("Zahnarzt anrufen", action: "Fasse die Woche zusammen", agentID: agentID, context: context)

        let entries = try context.fetch(FetchDescriptor<ReminderEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].agentID, agentID)
        XCTAssertEqual(entries[0].content, "Zahnarzt anrufen")
        XCTAssertEqual(entries[0].actionPrompt, "Fasse die Woche zusammen")
        XCTAssertFalse(entries[0].isCompleted)
        XCTAssertTrue(result.contains("[\(entries[0].shortID)]"))
        XCTAssertEqual(scheduled.map(\.id), entries.map(\.id))
    }

    func testCreateAdmitsWhenNotificationNotScheduled() async throws {
        let context = try makeContext()
        provider.scheduleNotification = { _ in false }

        let result = try await create("Ohne Ton", agentID: UUID(), context: context)

        XCTAssertTrue(result.contains("could NOT be scheduled"))
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReminderEntry>()).count, 1)
    }

    func testCreateRejectsPastDate() async throws {
        let context = try makeContext()
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))

        await assertThrowsToolError(.pastDate(past)) {
            try await self.create("Zu spät", due: past, agentID: UUID(), context: context)
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReminderEntry>()).count, 0)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testCreateRejectsGarbageEmptyAndOversized() async throws {
        let context = try makeContext()
        let agentID = UUID()

        await assertThrowsToolError(.invalidDate("morgen irgendwann")) {
            try await self.create("Termin", due: "morgen irgendwann", agentID: agentID, context: context)
        }
        await assertThrowsToolError(.emptyContent) {
            try await self.create("   ", agentID: agentID, context: context)
        }
        await assertThrowsToolError(.contentTooLong(2_001)) {
            try await self.create(
                String(repeating: "x", count: 2_001), agentID: agentID, context: context
            )
        }
        await assertThrowsToolError(.missingArgument("content")) {
            try await self.provider.call(
                namespacedName: ReminderToolProvider.createToolName,
                argumentsJSON: #"{"due": "2027-01-01T09:00:00+01:00"}"#,
                agentID: agentID, context: context
            )
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReminderEntry>()).count, 0)
    }

    func testCreateParsesFractionalSeconds() async throws {
        let context = try makeContext()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let due = formatter.string(from: Date().addingTimeInterval(3_600))

        _ = try await create("Fraktional", due: due, agentID: UUID(), context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReminderEntry>()).count, 1)
    }

    /// ISO 8601 without a timezone designator is read as local wall time.
    func testParseDateWithoutTimezoneIsLocal() throws {
        var components = DateComponents()
        components.year = 2027
        components.month = 3
        components.day = 10
        components.hour = 9
        components.minute = 30
        components.second = 0
        let expected = try XCTUnwrap(Calendar.current.date(from: components))

        XCTAssertEqual(ReminderToolProvider.parseDate("2027-03-10T09:30:00"), expected)
        XCTAssertEqual(ReminderToolProvider.parseDate("2027-03-10T09:30"), expected)
    }

    func testParseDateKeepsExplicitOffsets() throws {
        // Same wall time, different offsets → different instants, both valid.
        let zurich = try XCTUnwrap(ReminderToolProvider.parseDate("2027-03-10T09:30:00+01:00"))
        let utc = try XCTUnwrap(ReminderToolProvider.parseDate("2027-03-10T09:30:00Z"))
        XCTAssertEqual(zurich.timeIntervalSince(utc), -3_600)
        XCTAssertNil(ReminderToolProvider.parseDate("garbage"))
    }

    func testListShowsOpenRemindersOnly() async throws {
        let context = try makeContext()
        let agentID = UUID()
        _ = try await create("Offen", agentID: agentID, context: context)
        let done = ReminderEntry(agentID: agentID, content: "Erledigt", dueDate: Date().addingTimeInterval(3_600))
        done.isCompleted = true
        context.insert(done)
        try context.save()

        let result = try await provider.call(
            namespacedName: ReminderToolProvider.listToolName,
            argumentsJSON: "{}",
            agentID: agentID, context: context
        )
        XCTAssertTrue(result.contains("Offen"))
        XCTAssertFalse(result.contains("Erledigt"))
    }

    func testCompleteAndDeleteCancelNotification() async throws {
        let context = try makeContext()
        let agentID = UUID()
        _ = try await create("Eins", agentID: agentID, context: context)
        _ = try await create("Zwei", agentID: agentID, context: context)
        let entries = try context.fetch(FetchDescriptor<ReminderEntry>())
        XCTAssertEqual(entries.count, 2)

        _ = try await provider.call(
            namespacedName: ReminderToolProvider.completeToolName,
            argumentsJSON: #"{"id": "\#(entries[0].shortID)"}"#,
            agentID: agentID, context: context
        )
        XCTAssertTrue(entries[0].isCompleted)
        XCTAssertEqual(cancelled, [entries[0].id])

        _ = try await provider.call(
            namespacedName: ReminderToolProvider.deleteToolName,
            argumentsJSON: #"{"id": "\#(String(entries[1].shortID.prefix(4)))"}"#,
            agentID: agentID, context: context
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReminderEntry>()).count, 1)
        XCTAssertEqual(Set(cancelled), Set(entries.map(\.id)))
    }

    func testUnknownIDThrows() async throws {
        let context = try makeContext()
        await assertThrowsToolError(.entryNotFound("deadbeef")) {
            try await self.provider.call(
                namespacedName: ReminderToolProvider.completeToolName,
                argumentsJSON: #"{"id": "deadbeef"}"#,
                agentID: UUID(), context: context
            )
        }
    }

    func testEntriesAreScopedPerAgent() async throws {
        let context = try makeContext()
        let agentA = UUID()
        let agentB = UUID()
        _ = try await create("As Erinnerung", agentID: agentA, context: context)

        // B's prompt must not leak A's reminders, and B can't touch A's entry.
        let sectionB = provider.systemPromptSection(agentID: agentB, context: context)
        XCTAssertFalse(sectionB.contains("As Erinnerung"))

        let entry = try XCTUnwrap(context.fetch(FetchDescriptor<ReminderEntry>()).first)
        await assertThrowsToolError(.entryNotFound(entry.shortID)) {
            try await self.provider.call(
                namespacedName: ReminderToolProvider.deleteToolName,
                argumentsJSON: #"{"id": "\#(entry.shortID)"}"#,
                agentID: agentB, context: context
            )
        }
    }

    func testPromptSectionCarriesTimeAnchorAndOpenEntries() async throws {
        let context = try makeContext()
        let agentID = UUID()
        _ = try await create("Milch kaufen", agentID: agentID, context: context)

        let section = provider.systemPromptSection(agentID: agentID, context: context)
        let entry = try XCTUnwrap(context.fetch(FetchDescriptor<ReminderEntry>()).first)
        XCTAssertTrue(section.contains("[\(entry.shortID)] Milch kaufen"))
        XCTAssertTrue(section.contains("Current local time:"))
        XCTAssertFalse(section.contains("OVERDUE"))

        entry.dueDate = Date().addingTimeInterval(-60)
        try context.save()
        let overdueSection = provider.systemPromptSection(agentID: agentID, context: context)
        XCTAssertTrue(overdueSection.contains("OVERDUE"))
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
