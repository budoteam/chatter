import Foundation
import SwiftData
import SwiftUI

/// Drives one `ChatView`: composer text, send/stop, and error surfacing.
@MainActor
@Observable
final class ChatViewModel {
    var inputText = ""
    var pendingImages: [ImageAttachment] = []
    var isSending = false
    var errorMessage: String?

    private var task: Task<Void, Never>?

    var canSend: Bool {
        guard !isSending else { return false }
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !pendingImages.isEmpty
    }

    func send(env: AppEnvironment, session: ChatSession, agent: Agent?, context: ModelContext) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        guard (!text.isEmpty || !images.isEmpty), !isSending else { return }
        inputText = ""
        pendingImages = []
        isSending = true

        task = Task {
            do {
                try await env.engine.send(text: text, images: images, session: session, agent: agent, context: context)
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
