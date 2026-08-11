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
    var canAttachImages = false
    /// Set when an offered image was refused because it would push the message's
    /// attachments past the iCloud-sync size budget; read by the composer banner.
    var imageLimitHit = false

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

        env.runTurn(for: session, context: context) { [weak self] in
            do {
                try await env.engine.send(text: text, images: images, session: session, agent: agent, context: context)
            } catch is CancellationError {
                // User stopped — nothing to surface.
            } catch let error as ChatEngine.EngineError {
                self?.errorMessage = error.localizedDescription
                // Only noModel is thrown before anything was persisted —
                // without this the cleared draft would be gone entirely.
                // Later failures (e.g. visionFallbackFailed) leave the user
                // message in history; restoring the draft would duplicate it
                // on the next send. Retry then goes through resend/regenerate.
                if case .noModel = error, let self, self.inputText.isEmpty, self.pendingImages.isEmpty {
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

    /// Appends pre-encoded images under the CloudKit size budget; images that
    /// would exceed it are skipped and surface the budget hint. Shared sink for
    /// the photo picker, paste, drop, and the file panel.
    func addBase64Images(_ base64s: [String]) {
        var skipped = false
        for base64 in base64s {
            let used = pendingImages.reduce(0) { $0 + $1.base64.utf8.count }
            guard used + base64.utf8.count <= ImageAttachment.maxBase64BytesPerMessage else {
                skipped = true
                continue
            }
            pendingImages.append(ImageAttachment(base64: base64))
        }
        imageLimitHit = skipped
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

        // Snapshot before deleting: if the regenerate turn fails (no API key,
        // network down), the deleted history would otherwise be gone for good.
        let stale = ordered.filter { $0.orderIndex > anchor.orderIndex }
        let snapshots = stale.map(MessageSnapshot.init)
        for message in stale {
            context.delete(message)
        }
        context.saveOrLog()

        env.runTurn(for: session, context: context) { [weak self] in
            do {
                try await env.engine.regenerate(session: session, agent: session.agent, context: context)
            } catch is CancellationError {
                // User stopped — nothing to surface.
            } catch {
                // The replacement failed: drop whatever the attempt left
                // behind and restore the deleted history.
                for leftover in session.orderedMessages where leftover.orderIndex > anchor.orderIndex {
                    context.delete(leftover)
                }
                for snapshot in snapshots {
                    snapshot.restore(into: context, session: session)
                }
                context.saveOrLog()
                self?.errorMessage = error.localizedDescription
            }
            Self.finishStreaming(session: session, context: context)
        }
    }

    /// Deletes exactly this one message.
    func delete(_ message: Message, context: ModelContext) {
        context.delete(message)
        context.saveOrLog()
    }

    /// Ensure no message is left flagged as streaming after stop/error.
    private static func finishStreaming(session: ChatSession, context: ModelContext) {
        for message in session.orderedMessages where message.isStreaming {
            message.isStreaming = false
        }
        context.saveOrLog()
    }
}

/// Value copy of a message, so a failed resend/regenerate turn can put the
/// deleted history back instead of losing it for good.
private struct MessageSnapshot {
    let roleRaw: String
    let content: String
    let orderIndex: Int
    let createdAt: Date
    let toolCallsJSON: String?
    let attachmentsJSON: String?
    let toolName: String?
    let thinking: String?

    init(_ message: Message) {
        roleRaw = message.roleRaw
        content = message.content
        orderIndex = message.orderIndex
        createdAt = message.createdAt
        toolCallsJSON = message.toolCallsJSON
        attachmentsJSON = message.attachmentsJSON
        toolName = message.toolName
        thinking = message.thinking
    }

    func restore(into context: ModelContext, session: ChatSession) {
        let message = Message(
            role: MessageRole(rawValue: roleRaw) ?? .user,
            content: content, orderIndex: orderIndex, toolName: toolName
        )
        message.createdAt = createdAt
        message.toolCallsJSON = toolCallsJSON
        message.attachmentsJSON = attachmentsJSON
        message.thinking = thinking
        message.session = session
        context.insert(message)
    }
}
