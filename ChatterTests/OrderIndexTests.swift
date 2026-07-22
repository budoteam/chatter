import XCTest
import SwiftData
@testable import Chatter

/// `ChatSession.orderedMessages` must stay deterministic when CloudKit merges
/// produce duplicate `orderIndex` values: ties break by `createdAt`, then by
/// `id.uuidString`.
@MainActor
final class OrderIndexTests: XCTestCase {
    // ModelContext does not retain its container; a local would deallocate on
    // return and the first insert would trap inside SwiftData.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: ChatSession.self, Message.self, Artifact.self,
            // In the hosted test process the `.automatic` default would hook
            // the in-memory store into the app's CloudKit mirroring (crash on
            // save: "No eligible connection available").
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        self.container = container
        return container.mainContext
    }

    private func makeMessage(
        content: String, orderIndex: Int, createdAt: Date, session: ChatSession, context: ModelContext
    ) -> Message {
        let message = Message(role: .user, content: content, orderIndex: orderIndex)
        message.createdAt = createdAt
        message.session = session
        context.insert(message)
        return message
    }

    func testSameOrderIndexBreaksTieByCreatedAt() throws {
        let context = try makeContext()
        let session = ChatSession()
        context.insert(session)

        let newer = makeMessage(
            content: "neu", orderIndex: 5,
            createdAt: Date(timeIntervalSince1970: 2_000), session: session, context: context
        )
        let older = makeMessage(
            content: "alt", orderIndex: 5,
            createdAt: Date(timeIntervalSince1970: 1_000), session: session, context: context
        )

        XCTAssertEqual(
            session.orderedMessages.map(\.id), [older.id, newer.id],
            "smaller createdAt wins the orderIndex tie"
        )
        XCTAssertEqual(
            session.orderedMessages.map(\.id), session.orderedMessages.map(\.id),
            "sorting must be deterministic across evaluations"
        )
    }

    func testEqualOrderIndexAndCreatedAtBreaksTieByID() throws {
        let context = try makeContext()
        let session = ChatSession()
        context.insert(session)

        let stamp = Date(timeIntervalSince1970: 1_000)
        let a = makeMessage(content: "a", orderIndex: 0, createdAt: stamp, session: session, context: context)
        let b = makeMessage(content: "b", orderIndex: 0, createdAt: stamp, session: session, context: context)

        let expected = [a, b].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)
        XCTAssertEqual(session.orderedMessages.map(\.id), expected)
        XCTAssertEqual(session.orderedMessages.map(\.id), session.orderedMessages.map(\.id))
    }
}
