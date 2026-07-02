import Foundation
import SwiftData
import SwiftUI

/// Drives one `ChatView`: composer text, send/stop, and error surfacing.
@MainActor
@Observable
final class ChatViewModel {
    var inputText = ""
    var isSending = false
    var errorMessage: String?

    private var task: Task<Void, Never>?

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    func send(env: AppEnvironment, session: ChatSession, agent: Agent?, context: ModelContext) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        inputText = ""
        isSending = true

        task = Task {
            do {
                try await env.engine.send(text: text, session: session, agent: agent, context: context)
            } catch is CancellationError {
                // User stopped — nothing to surface.
            } catch {
                errorMessage = error.localizedDescription
            }
            finishStreaming(session: session, context: context)
            isSending = false
        }
    }

    func stop() {
        task?.cancel()
    }

    /// Ensure no message is left flagged as streaming after stop/error.
    private func finishStreaming(session: ChatSession, context: ModelContext) {
        for message in session.orderedMessages where message.isStreaming {
            message.isStreaming = false
        }
        try? context.save()
    }
}
