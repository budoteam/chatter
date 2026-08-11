#if os(macOS)
import Foundation
import SwiftData

/// Server side of the CloudKit handoff (see SERVER-HANDOFF.md): polls for
/// `HandoffRequest`s from the user's other devices, claims them, and runs
/// the assistant turn locally. Always active — with no requests pending it
/// costs one cheap local fetch per interval; CloudKit (same Apple ID) is
/// the access control, so no toggle or pairing exists. macOS-only: the app
/// keeps running without windows, and stdio MCP works here.
@MainActor
final class HandoffServer {
    private let environment: AppEnvironment
    private let context: ModelContext
    private var timer: Timer?

    init(environment: AppEnvironment, context: ModelContext, interval: TimeInterval = 15) {
        self.environment = environment
        self.context = context
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.poll() }
        }
    }

    private func poll() {
        guard Persistence.storeMode == .cloudKit else { return }
        let now = Date()
        let requests = (try? context.fetch(FetchDescriptor<HandoffRequest>())) ?? []
        guard let request = requests
            .filter({
                HandoffCoordinator.isEligibleForClaim($0, now: now)
                    && !environment.activeTurnSessionIDs.contains($0.sessionID)
            })
            .min(by: { $0.createdAt < $1.createdAt }) else { return }
        claimAndRun(request, now: now)
    }

    private func claimAndRun(_ request: HandoffRequest, now: Date) {
        request.claimedBy = AppSettings.deviceID
        request.claimedAt = now
        context.saveOrLog()
        AppLogger.data.info("Handoff claimed for session \(request.sessionID.uuidString, privacy: .public)")

        Task { @MainActor in
            // SwiftData has no compare-and-swap: a second Mac may have
            // claimed concurrently. Verify our claim survived a sync round.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, request.claimedBy == AppSettings.deviceID else { return }

            let sessionID = request.sessionID
            guard let session = try? context.fetch(
                FetchDescriptor<ChatSession>(predicate: #Predicate { $0.id == sessionID })
            ).first else {
                request.preview = "Session not found on the server."
                request.completedAt = .now
                context.saveOrLog()
                return
            }

            // The requesting device may have died mid-stream: close dangling
            // streaming flags so the chat doesn't spin forever.
            for message in session.orderedMessages where message.isStreaming {
                message.isStreaming = false
            }
            context.saveOrLog()

            // Heartbeat against stale-claim takeovers. Created inside the
            // turn closure: `runTurn` returns immediately (it enqueues the
            // turn task) and no-ops without calling the closure when a turn
            // is already active — a heartbeat created here would either die
            // at once (defer) or leak forever.
            environment.runTurn(for: session, context: context) { [environment, context] in
                let heartbeat = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        guard !Task.isCancelled else { return }
                        request.claimedAt = .now
                        context.saveOrLog()
                    }
                }
                defer { heartbeat.cancel() }
                do {
                    try await environment.engine.regenerate(
                        session: session, agent: session.agent, context: context
                    )
                    request.preview = session.orderedMessages
                        .last(where: { $0.role == .assistant })
                        .map { String($0.content.prefix(200)) } ?? ""
                } catch is CancellationError {
                    // Local stop on this Mac — fall through with whatever
                    // partial state exists.
                } catch {
                    AppLogger.api.error("Handoff turn failed: \(error.localizedDescription, privacy: .public)")
                    request.preview = "Handoff failed: \(error.localizedDescription)"
                }
                if request.preview.isEmpty {
                    request.preview = "Turn finished on the server."
                }
                request.completedAt = .now
                context.saveOrLog()
            }
        }
    }
}
#endif
