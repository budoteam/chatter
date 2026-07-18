import XCTest
import SwiftData
@testable import Chatter

/// Dispatch round-trips, authoring rules, and prompt index for skills.
@MainActor
final class SkillToolProviderTests: XCTestCase {
    // ModelContext does not retain its container; a local would deallocate on
    // return and the first insert would trap inside SwiftData.
    private var container: ModelContainer?
    private let provider = SkillToolProvider()

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

    private func makeAgent(in context: ModelContext, authoring: Bool = true) -> Agent {
        let agent = Agent(name: "Test", skillAuthoringEnabled: authoring)
        context.insert(agent)
        return agent
    }

    private func create(
        name: String, summary: String = "Wann nutzen", content: String = "1. Schritt",
        agent: Agent, context: ModelContext
    ) throws -> String {
        try provider.call(
            namespacedName: SkillToolProvider.createToolName,
            argumentsJSON: #"{"name": "\#(name)", "summary": "\#(summary)", "content": "\#(content)"}"#,
            agent: agent, context: context
        )
    }

    func testCreateSlugifiesAndAutoEnables() throws {
        let context = try makeContext()
        let agent = makeAgent(in: context)

        let result = try create(name: "Weekly Report!", agent: agent, context: context)

        let skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(skill.name, "weekly-report")
        XCTAssertTrue(agent.skillIDs.contains(skill.id), "created skill must be enabled for the author")
        XCTAssertTrue(result.contains("weekly-report"))
    }

    func testCreateRejectsDuplicateNameGlobally() throws {
        let context = try makeContext()
        let author = makeAgent(in: context)
        _ = try create(name: "deploy", agent: author, context: context)

        // A different agent may not reuse the name either — the pool is global.
        let other = makeAgent(in: context)
        XCTAssertThrowsError(try create(name: "Deploy", agent: other, context: context)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("already exists"))
        }
    }

    func testReadIsCaseInsensitiveAndTruncates() throws {
        let context = try makeContext()
        let agent = makeAgent(in: context)
        let long = String(repeating: "z", count: 20_000)
        _ = try create(name: "big-skill", content: long, agent: agent, context: context)

        let text = try provider.call(
            namespacedName: SkillToolProvider.readToolName,
            argumentsJSON: #"{"name": "BIG-SKILL"}"#,
            agent: agent, context: context
        )
        XCTAssertTrue(text.hasPrefix("Skill: big-skill"))
        XCTAssertTrue(text.contains("truncated"))
        XCTAssertLessThan(text.count, 16_100)
    }

    func testReadUnknownNameListsAvailable() throws {
        let context = try makeContext()
        let agent = makeAgent(in: context)
        _ = try create(name: "known", agent: agent, context: context)

        XCTAssertThrowsError(try provider.call(
            namespacedName: SkillToolProvider.readToolName,
            argumentsJSON: #"{"name": "unknown"}"#,
            agent: agent, context: context
        )) {
            XCTAssertTrue("\($0.localizedDescription)".contains("known"))
        }
    }

    func testUpdateOnlyTouchesProvidedFieldsAndOnlyEnabledSkills() throws {
        let context = try makeContext()
        let author = makeAgent(in: context)
        _ = try create(name: "proc", summary: "Alt", content: "Alt", agent: author, context: context)
        let skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first)

        _ = try provider.call(
            namespacedName: SkillToolProvider.updateToolName,
            argumentsJSON: #"{"name": "proc", "content": "Neu"}"#,
            agent: author, context: context
        )
        XCTAssertEqual(skill.content, "Neu")
        XCTAssertEqual(skill.summary, "Alt", "summary must stay untouched")

        // Another agent that hasn't enabled the skill can't rewrite it.
        let other = makeAgent(in: context)
        XCTAssertThrowsError(try provider.call(
            namespacedName: SkillToolProvider.updateToolName,
            argumentsJSON: #"{"name": "proc", "content": "Fremd"}"#,
            agent: other, context: context
        ))

        // At least one field is required.
        XCTAssertThrowsError(try provider.call(
            namespacedName: SkillToolProvider.updateToolName,
            argumentsJSON: #"{"name": "proc"}"#,
            agent: author, context: context
        ))
    }

    func testPromptSectionVariants() throws {
        let context = try makeContext()
        let agent = makeAgent(in: context, authoring: false)

        // No skills, no authoring → nothing to say.
        XCTAssertNil(provider.systemPromptSection(
            skillIDs: [], authoringEnabled: false, context: context
        ))

        // Authoring with zero skills → bootstrapping guidance is present.
        let bootstrap = try XCTUnwrap(provider.systemPromptSection(
            skillIDs: [], authoringEnabled: true, context: context
        ))
        XCTAssertTrue(bootstrap.contains(SkillToolProvider.createToolName))

        // Enabled skill → index line with name and summary; dangling IDs skipped.
        agent.skillAuthoringEnabled = true
        _ = try create(name: "report", summary: "Montags-Report", agent: agent, context: context)
        let section = try XCTUnwrap(provider.systemPromptSection(
            skillIDs: agent.skillIDs + [UUID()], authoringEnabled: false, context: context
        ))
        XCTAssertTrue(section.contains("- report: Montags-Report"))
    }

    func testToolGating() throws {
        let context = try makeContext()
        let agent = makeAgent(in: context)
        _ = try create(name: "one", agent: agent, context: context)

        // No skills + no authoring → no tools at all.
        XCTAssertTrue(provider.tools(skillIDs: [], authoringEnabled: false, context: context).isEmpty)
        // Authoring alone → read + create + update (read must work same-turn).
        XCTAssertEqual(
            Set(provider.tools(skillIDs: [], authoringEnabled: true, context: context).map(\.function.name)),
            [SkillToolProvider.readToolName, SkillToolProvider.createToolName, SkillToolProvider.updateToolName]
        )
        // Skills without authoring → read only.
        XCTAssertEqual(
            provider.tools(skillIDs: agent.skillIDs, authoringEnabled: false, context: context).map(\.function.name),
            [SkillToolProvider.readToolName]
        )
    }

    func testSchemasParseAsObjects() throws {
        let context = try makeContext()
        for tool in provider.tools(skillIDs: [], authoringEnabled: true, context: context) {
            guard case .object(let schema) = JSONValue.parse(tool.function.parameters.jsonString) else {
                return XCTFail("schema of \(tool.function.name) is not a JSON object")
            }
            XCTAssertEqual(schema["type"], .string("object"))
        }
    }
}
