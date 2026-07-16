import Foundation
import SwiftData
import SwiftUI

/// Drives one `ChatView`: composer text, send/stop, and error surfacing.
@MainActor
@Observable
final class ChatViewModel {
    var inputText = ""
    var pendingImages: [ImageAttachment] = []
    var errorMessage: String?

    /// Whether the composer holds sendable content. Whether a send may start
    /// also depends on the session's turn state, which `AppEnvironment` owns
    /// (it must survive this view model being recreated on session switches).
    var hasDraft: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !pendingImages.isEmpty
    }

    func send(env: AppEnvironment, session: ChatSession, agent: Agent?, context: ModelContext) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        guard (!text.isEmpty || !images.isEmpty), !env.isSending(session) else { return }
        inputText = ""
        pendingImages = []

        env.runTurn(for: session) { [weak self] in
            do {
                try await env.engine.send(text: text, images: images, session: session, agent: agent, context: context)
            } catch is CancellationError {
                // User stopped — nothing to surface.
            } catch let error as ChatEngine.EngineError {
                // Thrown before anything was persisted (e.g. no model
                // selected) — without this the cleared draft would be gone
                // entirely. Restore it unless the user typed on meanwhile.
                self?.errorMessage = error.localizedDescription
                if let self, self.inputText.isEmpty, self.pendingImages.isEmpty {
                    self.inputText = text
                    self.pendingImages = images
                }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            Self.finishStreaming(session: session, context: context)
        }
    }

    func stop(env: AppEnvironment, session: ChatSession) {
        env.stopTurn(for: session)
    }

    /// "Redo from here": drops everything after the anchoring user message
    /// (for answers: the user message that led to them) and regenerates the
    /// assistant turn from the remaining history.
    func resend(from message: Message, env: AppEnvironment, session: ChatSession, context: ModelContext) {
        guard !env.isSending(session) else { return }
        let ordered = session.orderedMessages
        let anchor: Message? = message.role == .user
            ? message
            : ordered.last { $0.role == .user && $0.orderIndex < message.orderIndex }
        guard let anchor else { return }

        for stale in ordered where stale.orderIndex > anchor.orderIndex {
            context.delete(stale)
        }
        try? context.save()

        env.runTurn(for: session) { [weak self] in
            do {
                try await env.engine.regenerate(session: session, agent: session.agent, context: context)
            } catch is CancellationError {
                // User stopped — nothing to surface.
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            Self.finishStreaming(session: session, context: context)
        }
    }

    /// Deletes exactly this one message.
    func delete(_ message: Message, context: ModelContext) {
        context.delete(message)
        try? context.save()
    }

    /// Ensure no message is left flagged as streaming after stop/error.
    private static func finishStreaming(session: ChatSession, context: ModelContext) {
        for message in session.orderedMessages where message.isStreaming {
            message.isStreaming = false
        }
        try? context.save()
    }
}
