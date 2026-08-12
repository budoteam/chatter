import Foundation
import SwiftData
import SwiftUI

/// Which screen the detail (main) column shows. `.chat` falls back to the
/// welcome view when no session is selected.
enum MainScreen {
    case chat
    case agents
    case knowledge
    case skills
}

/// Root observable object: owns the shared services and cross-view UI state
/// (current selection, cached model list, API-key presence).
@MainActor
@Observable
final class AppEnvironment {
    let ollama: OllamaServiceProtocol
    let mcp: MCPConnectionManager
    let knowledge: KnowledgeToolProvider
    let artifacts: ArtifactToolProvider
    let engine: ChatEngine
    /// Watches CloudKit sync events for the Settings status section.
    let sync = CloudSyncMonitor()

    var selectedSession: ChatSession?
    /// Which screen the detail column shows (chat / agents / knowledge).
    var mainScreen: MainScreen = .chat
    var models: [OllamaModel] = []
    var isLoadingModels = false
    var modelLoadError: String?
    var hasAPIKey: Bool = KeychainService.hasAPIKey
    /// Cached `/api/show` capabilities per model name (lowercased set).
    var modelCapabilities: [String: Set<String>] = [:]
    /// Mirror of `AppSettings.visionModel` for SwiftUI reactivity; writes persist.
    var visionModel: String = AppSettings.visionModel {
        didSet { AppSettings.visionModel = visionModel }
    }
    /// Text to pre-fill the composer of the next opened chat (welcome chips).
    var pendingPrompt: String?

    /// Artifact shown in the side panel (macOS) or sheet (iOS); set by
    /// tapping an artifact pill in the chat, cleared by closing the panel.
    var openArtifactID: PersistentIdentifier?

    /// Bumped by the macOS "New Chat" menu command; observed by `RootView`.
    private(set) var newSessionRequestID = UUID()

    /// Set when "New Chat" was requested while no `RootView` existed to observe
    /// the `newSessionRequestID` bump (main window closed on macOS); consumed by
    /// the next appearing `RootView` via `takePendingNewSession()`.
    private(set) var pendingNewSession = false

    /// Bumped on every explicit pick of a screen or chat; observed by
    /// `RootView` to surface the detail column on iPhone. A plain
    /// `onChange(of: mainScreen)` misses re-picking the still-active screen
    /// after popping back to the sidebar (value unchanged → no change event).
    private(set) var detailRequestID = UUID()

    /// Live assistant turns keyed by session id. Owned here (not by the chat
    /// view) because `ChatView` — and with it any view-local state — is
    /// recreated whenever the selection changes (`.id(session.id)`); the turn
    /// keeps running across that, and coming back must still show Stop and
    /// refuse a concurrent second send into the same session.
    private var activeTurns: [UUID: Task<Void, Never>] = [:]

    init() {
        let ollama = OllamaService()
        let mcp = MCPConnectionManager()
        let knowledge = KnowledgeToolProvider()
        let artifacts = ArtifactToolProvider()
        self.ollama = ollama
        self.mcp = mcp
        self.knowledge = knowledge
        self.artifacts = artifacts
        self.engine = ChatEngine(ollama: ollama, mcp: mcp, knowledge: knowledge, artifacts: artifacts)
        // Tool rounds are the only progress signal a turn has; the keeper
        // maps them onto the iOS 26 continued-processing Live Activity.
        engine.onToolRound = { sessionID, round, maxRounds in
            TurnRuntimeKeeper.updateProgress(sessionID: sessionID, toolRound: round, maxRounds: maxRounds)
        }
        #if os(iOS) || os(watchOS)
        // iCloud Keychain doesn't reliably sync to watchOS; the watch pulls
        // the API key from the paired iPhone over WatchConnectivity instead.
        WatchKeySync.shared.activate()
        #if os(watchOS)
        WatchKeySync.shared.onKeyReceived = { [weak self] in
            self?.refreshAPIKeyState()
            Task { await self?.refreshModels() }
        }
        #endif
        #endif
    }

    func requestNewSession() {
        pendingNewSession = true
        newSessionRequestID = UUID()
    }

    /// Clears the pending flag; returns whether a request was pending. Called by
    /// `RootView` both when it observes the ID bump and when it first appears, so
    /// a request fired while the window was closed is not lost.
    func takePendingNewSession() -> Bool {
        defer { pendingNewSession = false }
        return pendingNewSession
    }

    /// Switches the detail column to a screen (sidebar nav buttons).
    func showScreen(_ screen: MainScreen) {
        mainScreen = screen
        detailRequestID = UUID()
    }

    /// Selects a session and switches the detail column back to the chat view
    /// (used when starting/opening a chat from the Agents overview).
    func openChat(_ session: ChatSession) {
        selectedSession = session
        mainScreen = .chat
        detailRequestID = UUID()
    }

    // MARK: - Turn lifecycle

    func isSending(_ session: ChatSession) -> Bool {
        activeTurns[session.id] != nil
    }

    /// Sessions with a locally running turn — the handoff server skips
    /// these (no point executing a turn this Mac is already running).
    var activeTurnSessionIDs: Set<UUID> { Set(activeTurns.keys) }

    /// Why a turn was stopped. `.handoff` means a server claimed the turn:
    /// the completion notification is suppressed (the server reports
    /// completion through the request) and the request stays open.
    enum TurnStopReason {
        case user, handoff
    }

    /// Sessions whose turn was stopped for handoff — consumed by the
    /// `runTurn` teardown.
    private var suppressedCompletions: Set<UUID> = []

    /// Sessions this device published a handoff request for (set on
    /// backgrounding) — the `runTurn` teardown only withdraws those, so
    /// plain local turns and the never-publishing Mac/watch pay no CloudKit
    /// query on completion.
    private var publishedHandoffs: Set<UUID> = []

    /// Runs one assistant turn for the session; no-op while one is running.
    /// The turn is wrapped in `TurnRuntimeKeeper` so it survives the app
    /// going to the background (iOS), and finishing while inactive posts a
    /// local notification. A locally finished turn withdraws its handoff
    /// request — nothing left for a server to do.
    func runTurn(for session: ChatSession, context: ModelContext, _ body: @escaping @MainActor () async -> Void) {
        let id = session.id
        guard activeTurns[id] == nil else { return }
        TurnRuntimeKeeper.begin(sessionID: id, subtitle: session.title) { [weak self] in
            self?.stopTurn(for: session)
        }
        activeTurns[id] = Task { @MainActor in
            await body()
            activeTurns[id] = nil
            TurnRuntimeKeeper.end(sessionID: id)
            let handedOff = suppressedCompletions.remove(id) != nil
            let published = publishedHandoffs.remove(id) != nil
            guard !handedOff else { return }
            if published, Persistence.storeMode == .cloudKit {
                await HandoffChannel.cancelOpenRequests(sessionID: id)
            }
            let preview = session.orderedMessages
                .last(where: { $0.role == .assistant })
                .map { String($0.content.prefix(200)) } ?? "Reply ready"
            await TurnRuntimeKeeper.notifyCompletionIfNeeded(
                sessionID: id, title: session.title, preview: preview
            )
        }
    }

    func stopTurn(for session: ChatSession, reason: TurnStopReason = .user) {
        if reason == .handoff { suppressedCompletions.insert(session.id) }
        activeTurns[session.id]?.cancel()
    }

    /// Cancels a running turn and waits for its teardown (final flush and
    /// saves) to finish — required before deleting the session, so the engine
    /// never mutates models that are already gone.
    func cancelTurnAndWait(for session: ChatSession) async {
        guard let task = activeTurns[session.id] else { return }
        task.cancel()
        await task.value
    }

    func refreshAPIKeyState() { hasAPIKey = KeychainService.hasAPIKey }

    // MARK: - Handoff (iOS requesting side)

    #if os(iOS)
    /// Backgrounding with live turns: publish a handoff request per active
    /// session so any Mac of this iCloud account can take over (the local
    /// turn keeps running meanwhile — first finisher wins). Goes through
    /// `HandoffChannel`'s direct CloudKit writes: the SwiftData mirroring
    /// suspends its exports while the app is backgrounded, so a mirrored
    /// request would never leave the device in time.
    ///
    /// Creates unconditionally (dedup via `publishedHandoffs`): a query
    /// against a not-yet-existing record type fails, so a pre-create fetch
    /// would deadlock the very first request — and the write is what pushes
    /// the type into the Development schema. Stray duplicates (app killed
    /// between two backgroundings) are filtered server-side
    /// (`HandoffCoordinator.isStaleDuplicate`) and pruned.
    func requestHandoffsForActiveTurns(context: ModelContext) async {
        guard Persistence.storeMode == .cloudKit else { return }
        for sessionID in activeTurns.keys where !publishedHandoffs.contains(sessionID) {
            let descriptor = FetchDescriptor<ChatSession>(predicate: #Predicate { $0.id == sessionID })
            guard let session = try? context.fetch(descriptor).first else { continue }
            await HandoffChannel.create(HandoffRequest(sessionID: sessionID, sessionTitle: session.title))
            publishedHandoffs.insert(sessionID)
        }
    }

    /// Foreground again: withdraw open requests (local turns continue or
    /// are done), stop local copies of claimed turns, and sweep completions.
    func reconcileHandoffsOnActive(context: ModelContext) async {
        guard Persistence.storeMode == .cloudKit else { return }
        do {
            let requests = try await HandoffChannel.fetchAll()
            stopLocallyClaimedTurns(in: requests, context: context)
            await notifyCompletedHandoffs(in: requests)
        } catch {
            AppLogger.data.error("Handoff reconcile failed: \(error.localizedDescription, privacy: .public)")
        }
        await HandoffChannel.cancelOpenRequests()
        await HandoffChannel.prune()
    }

    /// Silent push (server wrote a claim or completion): adopt claims and
    /// notify — deliberately does NOT withdraw open requests, the app is
    /// still backgrounded with its local turn running.
    func handleHandoffPush(context: ModelContext) async {
        guard Persistence.storeMode == .cloudKit else { return }
        do {
            let requests = try await HandoffChannel.fetchAll()
            stopLocallyClaimedTurns(in: requests, context: context)
            await notifyCompletedHandoffs(in: requests)
        } catch {
            AppLogger.data.error("Handoff push handling failed: \(error.localizedDescription, privacy: .public)")
        }
        await HandoffChannel.prune()
    }

    private func stopLocallyClaimedTurns(in requests: [HandoffRequest], context: ModelContext) {
        for sessionID in activeTurns.keys {
            guard HandoffCoordinator.claimedRequest(for: sessionID, in: requests) != nil else { continue }
            let descriptor = FetchDescriptor<ChatSession>(predicate: #Predicate { $0.id == sessionID })
            guard let session = try? context.fetch(descriptor).first else { continue }
            AppLogger.data.info("Handoff claimed by a server, stopping local turn for \(sessionID.uuidString, privacy: .public)")
            stopTurn(for: session, reason: .handoff)
        }
    }

    /// Requests already notified this run — first-line dedup so a failed
    /// `markNotified` (network) doesn't re-post the same notification on the
    /// next reconcile. Intersected with the fetched set on each sweep.
    private var notifiedHandoffs: Set<UUID> = []

    private func notifyCompletedHandoffs(in requests: [HandoffRequest]) async {
        notifiedHandoffs.formIntersection(requests.map(\.id))
        for request in HandoffCoordinator.completedUnnotified(in: requests)
        where !notifiedHandoffs.contains(request.id) {
            notifiedHandoffs.insert(request.id)
            await TurnRuntimeKeeper.notifyCompletionIfNeeded(
                sessionID: request.sessionID,
                title: request.sessionTitle,
                preview: request.preview
            )
            // Marked even when the app is active (no notification posted) —
            // the user is looking at the result already.
            await HandoffChannel.markNotified(request)
        }
    }
    #endif

    // MARK: - Reminder actions

    /// Runs pending reminder actions: reminders whose `actionPrompt` became
    /// due while the app was closed (or while it sat in the background).
    /// Called at launch and from the notification delegate (tap). Each entry
    /// is stamped `actionCompletedAt` before its turn starts, so a crash or a
    /// second synced device can never double-run it — the stamp is the
    /// guard, not the outcome.
    func runDueReminderActions(context: ModelContext) {
        let now = Date()
        let descriptor = FetchDescriptor<ReminderEntry>(
            predicate: #Predicate { !$0.isCompleted && $0.dueDate <= now }
        )
        let due = ((try? context.fetch(descriptor)) ?? []).filter {
            !$0.actionPrompt.isEmpty && $0.actionCompletedAt == nil
        }
        guard !due.isEmpty else { return }

        for entry in due {
            entry.actionCompletedAt = now
            entry.updatedAt = now
            context.saveOrLog()
            // The notification is moot once the action runs.
            ReminderScheduler.cancel(entry.id)

            guard let agentID = entry.agentID,
                  let agent = try? context.fetch(
                      FetchDescriptor<Agent>(predicate: #Predicate { $0.id == agentID })
                  ).first else {
                // Agent deleted or reminder without one — nowhere to run it.
                AppLogger.data.error("Reminder action skipped, agent missing for \(entry.shortID, privacy: .public)")
                continue
            }

            let session = ChatSession(title: String(entry.content.prefix(48)), agent: agent)
            context.insert(session)
            context.saveOrLog()

            let prompt = entry.actionPrompt
            runTurn(for: session, context: context) { [weak self] in
                guard let self else { return }
                do {
                    try await self.engine.send(text: prompt, session: session, agent: agent, context: context)
                } catch {
                    AppLogger.api.error("Reminder action turn failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            // Bring the user to the result (with several due actions, the last
            // one wins — the others are one sidebar tap away).
            openChat(session)
        }
    }

    /// Loads the model list from Ollama Cloud (best-effort).
    func refreshModels() async {
        guard hasAPIKey else {
            models = []
            modelLoadError = "Add your Ollama API key in Settings."
            return
        }
        isLoadingModels = true
        modelLoadError = nil
        defer { isLoadingModels = false }
        do {
            models = try await ollama.listModels()
        } catch {
            modelLoadError = error.localizedDescription
            AppLogger.api.error("listModels failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether `model` reports `capability` via `/api/show`. Best-effort and
    /// cached: on any failure it returns false so gated features stay off
    /// rather than sending requests a model would ignore.
    func supports(_ capability: String, model: String) async -> Bool {
        guard !model.isEmpty else { return false }
        if let cached = modelCapabilities[model] { return cached.contains(capability) }
        guard hasAPIKey else { return false }
        do {
            let caps = Set(try await ollama.modelCapabilities(model: model).map { $0.lowercased() })
            modelCapabilities[model] = caps
            return caps.contains(capability)
        } catch {
            AppLogger.api.error("modelCapabilities failed for \(model, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Whether `model` supports image input (gates the composer photo button).
    func supportsVision(_ model: String) async -> Bool {
        await supports("vision", model: model)
    }

    /// Whether images may be attached in a chat running `model`: either the
    /// model itself reports vision, or the global vision fallback is configured.
    func canAttachImages(for model: String) async -> Bool {
        if await supportsVision(model) { return true }
        return !visionModel.isEmpty
    }
}
