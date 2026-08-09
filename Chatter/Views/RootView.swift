import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Agent.createdAt) private var agents: [Agent]

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var env = env
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            SidebarView(showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            Group {
                switch env.mainScreen {
                case .agents:
                    AgentsScreen()
                case .knowledge:
                    KnowledgeScreen()
                case .skills:
                    SkillsScreen()
                case .chat:
                    if let session = env.selectedSession {
                        ChatView(session: session)
                            .id(session.id)
                    } else {
                        WelcomeView(
                            onNewChat: startNewSession,
                            onSuggestion: { prompt in
                                env.pendingPrompt = prompt
                                startNewSession()
                            }
                        )
                    }
                }
            }
            .background(GeminiBackground())
        }
        .navigationSplitViewStyle(.balanced)
        // On iPhone (compact), surface the detail column when the user picks a
        // screen or opens a chat; on regular widths both columns stay visible.
        // Driven by an explicit request ID, not by value changes: re-picking
        // the still-active screen or chat after popping back to the sidebar
        // must also surface the detail column. Back-pop deselection doesn't
        // bump the ID, so the pop still reaches the sidebar untouched.
        .onChange(of: env.detailRequestID) { preferredColumn = .detail }
        #if os(macOS)
        .frame(minWidth: 860, minHeight: 560)
        #endif
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .task {
            resetStaleStreamingFlags()
            // Reminders: make this device schedule notifications for synced
            // entries, then run any action reminders that came due while the
            // app was closed.
            await ReminderScheduler.reconcile(context: context)
            env.runDueReminderActions(context: context)
            await env.refreshModels()
            backfillAgentModels()
            await env.mcp.syncConnections(configs: allServers())
            #if DEBUG
            ScreenshotDemo.applyNavigation(
                env: env,
                context: context,
                showSidebar: { preferredColumn = .sidebar },
                openSettings: { showSettings = true }
            )
            #endif
            // A "New Chat" request fired while the window was closed (macOS)
            // bumps the ID before this view exists; the pending flag survives
            // until here.
            if env.takePendingNewSession() { startNewSession() }
        }
        .onChange(of: env.newSessionRequestID) {
            env.takePendingNewSession()
            startNewSession()
        }
        .onChange(of: env.hasAPIKey) { Task { await env.refreshModels() } }
        #if os(iOS)
        // iOS suspension silently kills MCP sockets while the clients still
        // report connected — every tool call would then hang. Rebuild the
        // sessions whenever the app returns to the foreground.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await env.mcp.refreshConnections(configs: allServers()) }
        }
        #endif
    }

    private func startNewSession() {
        let agent = env.selectedSession?.agent ?? SessionFactory.defaultAgent(in: agents)
        let session = SessionFactory.create(in: context, agent: agent, models: env.models)
        env.openChat(session)
    }

    // No agent seeding on first launch: a fresh install must wait for the
    // CloudKit import instead of inserting its own "Assistant" — every device
    // used to do that, and the duplicates (all flagged default) synced
    // everywhere. Chats work without an agent until one is created/imported.

    /// Give any agent without a model (created while the list hadn't loaded)
    /// the first available one once we know it.
    private func backfillAgentModels() {
        guard let first = env.models.first?.name else { return }
        let all = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        var changed = false
        for agent in all where agent.modelId.isEmpty {
            agent.modelId = first
            changed = true
        }
        if changed { context.saveOrLog() }
    }

    private func allServers() -> [MCPServerConfig] {
        (try? context.fetch(FetchDescriptor<MCPServerConfig>())) ?? []
    }

    /// `isStreaming` is persisted (and CloudKit-synced), but only the live
    /// turn's teardown clears it — a force-quit or crash mid-stream leaves
    /// messages flagged forever (stuck typing indicator / "Thinking…").
    /// Nothing can be streaming this early in the launch, so clear leftovers.
    private func resetStaleStreamingFlags() {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.isStreaming == true }
        )
        let stale = (try? context.fetch(descriptor)) ?? []
        guard !stale.isEmpty else { return }
        for message in stale { message.isStreaming = false }
        context.saveOrLog()
        AppLogger.data.info("Reset \(stale.count) stale isStreaming flag(s) at launch")
    }
}
