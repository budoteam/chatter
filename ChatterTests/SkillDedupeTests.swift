import XCTest
import SwiftData
@testable import Chatter

/// Duplicate skill names can reach a device via CloudKit merges (the pool is
/// unique by convention, not by constraint). `skills__read` must resolve such
/// duplicates deterministically: the most recently updated copy wins.
@MainActor
final class SkillDedupeTests: XCTestCase {
    // ModelContext does not retain its container; a local would deallocate on
    // return and the first insert would trap inside SwiftData.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Agent.self, Skill.self,
            // In the hosted test process the `.automatic` default would hook
            // the in-memory store into the app's CloudKit mirroring (crash on
            // save: "No eligible connection available").
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        self.container = container
        return container.mainContext
    }

    func testReadPrefersMostRecentlyUpdatedDuplicate() throws {
        let context = try makeContext()

        let stale = Skill(name: "report", summary: "alt", content: "ALTER INHALT")
        stale.updatedAt = Date(timeIntervalSince1970: 1_000)
        let fresh = Skill(name: "Report", summary: "neu", content: "NEUER INHALT")
        fresh.updatedAt = Date(timeIntervalSince1970: 2_000)
        context.insert(stale)
        context.insert(fresh)

        let agent = Agent(name: "Test", skillIDs: [stale.id, fresh.id])
        context.insert(agent)

        let result = try SkillToolProvider().call(
            namespacedName: SkillToolProvider.readToolName,
            argumentsJSON: #"{"name": "REPORT"}"#,
            agent: agent, context: context
        )

        XCTAssertTrue(result.contains("NEUER INHALT"), "freshest duplicate must win")
        XCTAssertFalse(result.contains("ALTER INHALT"))
    }
}
