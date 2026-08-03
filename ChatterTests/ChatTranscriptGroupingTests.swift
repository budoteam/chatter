import XCTest
import SwiftData
@testable import Chatter

/// Grouping of the chat transcript into user / activity / answer items,
/// especially the mid-tool-loop stability: a streaming round that is not yet
/// known to be the final answer must join the ongoing activity group instead
/// of flipping between `.answer` and `.activity` every round.
@MainActor
final class ChatTranscriptGroupingTests: XCTestCase {
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

    /// Streaming round 2 of a tool loop (no persisted tool calls yet): with
    /// earlier steps present it must render as a step, so the whole loop
    /// stays ONE stable activity group — no answer item, `live == true`.
    func testStreamingRoundJoinsOngoingActivityGroup() throws {
        let context = try makeContext()
        let user = Message(role: .user, content: "go", orderIndex: 0)
        let a1 = Message(role: .assistant, content: "calling", orderIndex: 1)
        a1.toolCalls = [ToolCall(name: "srv__loop", argumentsJSON: "{}")]
        let tool = Message(role: .tool, content: "result", orderIndex: 2, toolName: "srv__loop")
        let a2 = Message(role: .assistant, content: "", orderIndex: 3, isStreaming: true)
        for message in [user, a1, tool, a2] { context.insert(message) }

        let items = ChatView.groupTranscript(messages: [user, a1, tool, a2], live: true)

        XCTAssertEqual(items.count, 2)
        guard case .user = items[0] else {
            return XCTFail("expected .user, got \(items[0])")
        }
        guard case .activity(let steps, let trailingThinking, let live) = items[1] else {
            return XCTFail("expected .activity, got \(items[1])")
        }
        XCTAssertTrue(live)
        XCTAssertNil(trailingThinking)
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps.map(\.orderIndex), [1, 2, 3])
    }

    /// First-round stream with no prior steps: a plain answer, no activity
    /// group frame around it.
    func testFirstRoundStreamsAsAnswer() throws {
        let context = try makeContext()
        let user = Message(role: .user, content: "hi", orderIndex: 0)
        let answer = Message(role: .assistant, content: "", orderIndex: 1, isStreaming: true)
        for message in [user, answer] { context.insert(message) }

        let items = ChatView.groupTranscript(messages: [user, answer], live: true)

        XCTAssertEqual(items.count, 2)
        guard case .user = items[0] else {
            return XCTFail("expected .user, got \(items[0])")
        }
        guard case .answer(_, let showsThinking) = items[1] else {
            return XCTFail("expected .answer, got \(items[1])")
        }
        XCTAssertTrue(showsThinking, "standalone answer renders its own thinking trace")
    }

    /// Regression for the pre-existing behavior: a finished loop groups its
    /// steps (not live) before the standalone final answer. The final round's
    /// thinking stays in the group as trailing thinking instead of rendering
    /// a second box under it.
    func testFinishedLoopGroupsStepsBeforeFinalAnswer() throws {
        let context = try makeContext()
        let user = Message(role: .user, content: "go", orderIndex: 0)
        let a1 = Message(role: .assistant, content: "calling", orderIndex: 1)
        a1.toolCalls = [ToolCall(name: "srv__loop", argumentsJSON: "{}")]
        let tool = Message(role: .tool, content: "result", orderIndex: 2, toolName: "srv__loop")
        let a2 = Message(role: .assistant, content: "done", orderIndex: 3)
        a2.thinking = "wrapping up"
        for message in [user, a1, tool, a2] { context.insert(message) }

        let items = ChatView.groupTranscript(messages: [user, a1, tool, a2], live: false)

        XCTAssertEqual(items.count, 3)
        guard case .user = items[0] else {
            return XCTFail("expected .user, got \(items[0])")
        }
        guard case .activity(let steps, let trailingThinking, let live) = items[1] else {
            return XCTFail("expected .activity, got \(items[1])")
        }
        XCTAssertFalse(live)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(trailingThinking, "wrapping up")
        guard case .answer(let final, let showsThinking) = items[2] else {
            return XCTFail("expected .answer, got \(items[2])")
        }
        XCTAssertEqual(final.content, "done")
        XCTAssertFalse(showsThinking, "thinking already rendered in the activity group")
    }
}
