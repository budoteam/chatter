#if os(macOS)
import Foundation
import SwiftData

/// Server side of the CloudKit handoff (see SERVER-HANDOFF.md): polls for
/// `HandoffRequest`s from the user's other devices, claims them, and runs
/// the assistant turn locally. Always active — with no requests pending it
/// costs one small CloudKit query per interval; CloudKit (same Apple ID) is
/// the access control, so no toggle or pairing exists. macOS-only: the app
/// keeps running without windows, and stdio MCP works here.
@MainActor
final class HandoffServer {
    private let environment: AppEnvironment
    private let context: ModelContext
    private var timer: Timer?
    /// Reentrancy guard: a poll's network round trips can outlast the timer
    /// interval; overlapping polls would double-claim.
    private var polling = false

    init(environment: AppEnvironment, context: ModelContext, interval: TimeInterval = 15) {
        self.environment = environment
        self.context = context
        Task { @MainActor in self.poll() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.poll() }
        }
    }

    private func poll() {
        guard Persistence.storeMode == .cloudKit, !polling else { return }
        polling = true
        Task { @MainActor in
            defer { polling = false }
            let now = Date()
            let requests: [HandoffRequest]
            do {
                requests = try await HandoffChannel.fetchAll()
            } catch {
                AppLogger.data.error("Handoff poll failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let request = requests
                .filter({
                    HandoffCoordinator.isEligibleForClaim($0, now: now)
                        && !HandoffCoordinator.isStaleDuplicate($0, in: requests, now: now)
                        && !environment.activeTurnSessionIDs.contains($0.sessionID)
                })
                .min(by: { $0.createdAt < $1.createdAt }) else { return }
            await claimAndRun(request, now: now)
        }
    }

    private func claimAndRun(_ request: HandoffRequest, now: Date) async {
        // Compare-and-swap replaces the old sleep-and-verify: the save only
        // lands if nobody touched the record since our fetch, so a second
        // Mac racing the same request simply loses and retries next poll.
        guard let claimed = await HandoffChannel.claim(request, by: AppSettings.deviceID, at: now)
        else { return }

        let sessionID = request.sessionID
        guard let session = try? context.fetch(
            FetchDescriptor<ChatSession>(predicate: #Predicate { $0.id == sessionID })
        ).first else {
            await HandoffChannel.complete(claimed, preview: "Session not found on the server.")
            return
        }

        // The requesting device may have died mid-stream: close dangling
        // streaming flags so the chat doesn't spin forever.
        for message in session.orderedMessages where message.isStreaming {
            message.isStreaming = false
        }
        context.saveOrLog()

        // The requesting phone's SwiftData export pauses in the background,
        // so the prompt this turn answers may never have synced. If it is
        // missing, run with the record's ephemeral copy — regenerating
        // against the stale store would re-answer the last SYNCED user
        // message (observed 2026-08-12: old question answered twice).
        let promptSynced = request.promptMessageID.map { promptID in
            session.orderedMessages.contains { $0.id == promptID }
        } ?? false

        // Heartbeat against stale-claim takeovers. Created inside the turn
        // closure: `runTurn` returns immediately (it enqueues the turn task)
        // and no-ops without calling the closure when a turn is already
        // active — a heartbeat created here would either die at once (defer)
        // or leak forever.
        environment.runTurn(for: session, context: context) { [environment, context] in
            var current = claimed
            let heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    current = await HandoffChannel.refreshClaim(current, at: .now)
                }
            }
            defer { heartbeat.cancel() }
            var preview: String
            do {
                if request.promptMessageID == nil || promptSynced {
                    try await environment.engine.regenerate(
                        session: session, agent: session.agent, context: context
                    )
                } else {
                    try await environment.engine.runHandoffTurn(
                        prompt: request.promptText,
                        promptOrderIndex: request.promptOrderIndex,
                        session: session, agent: session.agent, context: context
                    )
                }
                preview = session.orderedMessages
                    .last(where: { $0.role == .assistant })
                    .map { String($0.content.prefix(200)) } ?? ""
            } catch is CancellationError {
                // Local stop on this Mac — fall through with whatever
                // partial state exists.
                preview = ""
            } catch {
                AppLogger.api.error("Handoff turn failed: \(error.localizedDescription, privacy: .public)")
                preview = "Handoff failed: \(error.localizedDescription)"
            }
            if preview.isEmpty {
                preview = "Turn finished on the server."
            }
            await HandoffChannel.complete(current, preview: preview)
        }
    }
}
#endif
