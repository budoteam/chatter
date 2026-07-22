import XCTest
import SwiftData
@testable import Chatter

/// Upsert/replace semantics, size cap and persistence of `ArtifactToolProvider`
/// against an in-memory store.
@MainActor
final class ArtifactToolProviderTests: XCTestCase {
    // ModelContext does not retain its container; a local would deallocate on
    // return and the first insert would trap inside SwiftData.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Agent.self, ChatSession.self, Message.self, Artifact.self,
            // In the hosted test process the `.automatic` default would hook
            // the in-memory store into the app's CloudKit mirroring (crash on
            // save: "No eligible connection available").
            configurations: ModelConfiguration(
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        )
        self.container = container
        return container.mainContext
    }

    private func makeSession(in context: ModelContext) -> ChatSession {
        let session = ChatSession()
        context.insert(session)
        return session
    }

    private func allArtifacts(in context: ModelContext) throws -> [Artifact] {
        try context.fetch(FetchDescriptor<Artifact>())
    }

    private static func arguments(_ object: [String: JSONValue]) -> String {
        JSONValue.object(object).jsonString
    }

    func testCreateInsertsArtifact() throws {
        let context = try makeContext()
        let session = makeSession(in: context)
        let provider = ArtifactToolProvider()

        let result = try provider.call(
            name: ArtifactToolProvider.createToolName,
            argumentsJSON: Self.arguments([
                "name": .string("x.csv"),
                "kind": .string("csv"),
                "content": .string("a,b\n1,2"),
            ]),
            session: session,
            sourceToolCallID: "call-1",
            context: context
        )

        XCTAssertTrue(result.contains("x.csv"))
        let artifacts = try allArtifacts(in: context)
        XCTAssertEqual(artifacts.count, 1)
        let artifact = try XCTUnwrap(artifacts.first)
        XCTAssertEqual(artifact.name, "x.csv")
        XCTAssertEqual(artifact.kind, .csv)
        XCTAssertEqual(artifact.content, "a,b\n1,2")
        XCTAssertEqual(artifact.sourceToolCallID, "call-1")
        XCTAssertEqual(artifact.session?.id, session.id)
    }

    func testReplaceOverwritesExisting() throws {
        let context = try makeContext()
        let session = makeSession(in: context)
        let provider = ArtifactToolProvider()

        for content in ["a,b\n1,2", "a,b\n3,4"] {
            _ = try provider.call(
                name: ArtifactToolProvider.createToolName,
                argumentsJSON: Self.arguments([
                    "name": .string("x.csv"),
                    "kind": .string("csv"),
                    "content": .string(content),
                ]),
                session: session,
                sourceToolCallID: nil,
                context: context
            )
        }

        let artifacts = try allArtifacts(in: context)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts.first?.content, "a,b\n3,4")
    }

    func testReplaceFalseKeepsBothVersions() throws {
        let context = try makeContext()
        let session = makeSession(in: context)
        let provider = ArtifactToolProvider()

        for content in ["first", "second"] {
            _ = try provider.call(
                name: ArtifactToolProvider.createToolName,
                argumentsJSON: Self.arguments([
                    "name": .string("notes.md"),
                    "kind": .string("markdown"),
                    "content": .string(content),
                    "replace": .bool(false),
                ]),
                session: session,
                sourceToolCallID: nil,
                context: context
            )
        }

        XCTAssertEqual(try allArtifacts(in: context).count, 2)
    }

    func testTooLargeThrows() throws {
        let context = try makeContext()
        let session = makeSession(in: context)
        let provider = ArtifactToolProvider()
        let oversized = String(repeating: "x", count: ArtifactToolProvider.maxContentBytes + 1)

        XCTAssertThrowsError(
            try provider.call(
                name: ArtifactToolProvider.createToolName,
                argumentsJSON: Self.arguments([
                    "name": .string("big.csv"),
                    "content": .string(oversized),
                ]),
                session: session,
                sourceToolCallID: nil,
                context: context
            )
        ) { error in
            guard case ArtifactToolProvider.ToolError.artifactTooLarge = error else {
                return XCTFail("Expected artifactTooLarge, got \(error)")
            }
        }
        XCTAssertTrue(try allArtifacts(in: context).isEmpty)
    }

    func testMissingNameThrows() throws {
        let context = try makeContext()
        let session = makeSession(in: context)
        let provider = ArtifactToolProvider()

        XCTAssertThrowsError(
            try provider.call(
                name: ArtifactToolProvider.createToolName,
                argumentsJSON: Self.arguments(["content": .string("a,b")]),
                session: session,
                sourceToolCallID: nil,
                context: context
            )
        ) { error in
            guard case ArtifactToolProvider.ToolError.missingArgument(let arg) = error else {
                return XCTFail("Expected missingArgument, got \(error)")
            }
            XCTAssertEqual(arg, "name")
        }
    }

    func testUnknownKindDefaultsToCode() throws {
        let context = try makeContext()
        let session = makeSession(in: context)
        let provider = ArtifactToolProvider()

        _ = try provider.call(
            name: ArtifactToolProvider.createToolName,
            argumentsJSON: Self.arguments([
                "name": .string("weird.xyz"),
                "kind": .string("pdf"),
                "content": .string("body"),
            ]),
            session: session,
            sourceToolCallID: nil,
            context: context
        )

        XCTAssertEqual(try allArtifacts(in: context).first?.kind, .code)
    }

    /// Local-only verification: artifacts ride the session's CloudKit sync in
    /// production, but tests never touch the network — this only asserts the
    /// cascade relationship used for deletion is wired up.
    func testSessionCascadeDeleteRemovesArtifacts() throws {
        let context = try makeContext()
        let session = makeSession(in: context)
        let provider = ArtifactToolProvider()

        _ = try provider.call(
            name: ArtifactToolProvider.createToolName,
            argumentsJSON: Self.arguments([
                "name": .string("x.csv"),
                "content": .string("a,b\n1,2"),
            ]),
            session: session,
            sourceToolCallID: nil,
            context: context
        )
        XCTAssertEqual(try allArtifacts(in: context).count, 1)

        context.delete(session)
        context.saveOrLog()
        XCTAssertTrue(try allArtifacts(in: context).isEmpty)
    }
}
