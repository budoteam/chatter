import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Agent.createdAt) private var agents: [Agent]

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var showSettings = false

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
        .onChange(of: env.mainScreen) { preferredColumn = .detail }
        .onChange(of: env.selectedSession?.id) { preferredColumn = .detail }
        #if os(macOS)
        .frame(minWidth: 860, minHeight: 560)
        #endif
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .task {
            seedDefaultAgentIfNeeded()
            await env.refreshModels()
            backfillAgentModels()
            await env.mcp.syncConnections(configs: allServers())
        }
        .onChange(of: env.newSessionRequestID) { startNewSession() }
        .onChange(of: env.hasAPIKey) { Task { await env.refreshModels() } }
    }

    private func startNewSession() {
        let agent = env.selectedSession?.agent ?? SessionFactory.defaultAgent(in: agents)
        let session = SessionFactory.create(in: context, agent: agent, models: env.models)
        env.openChat(session)
    }

    private func seedDefaultAgentIfNeeded() {
        guard agents.isEmpty else { return }
        let assistant = Agent(
            name: "Assistant",
            systemPrompt: "You are a helpful, concise assistant.",
            modelId: env.models.first?.name ?? "",
            iconSymbol: "sparkles",
            colorHex: "6C5CE7",
            isDefault: true
        )
        context.insert(assistant)
        try? context.save()
    }

    /// Agents are seeded before the model list loads, so give any agent
    /// without a model the first available one once we know it.
    private func backfillAgentModels() {
        guard let first = env.models.first?.name else { return }
        let all = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        var changed = false
        for agent in all where agent.modelId.isEmpty {
            agent.modelId = first
            changed = true
        }
        if changed { try? context.save() }
    }

    private func allServers() -> [MCPServerConfig] {
        (try? context.fetch(FetchDescriptor<MCPServerConfig>())) ?? []
    }
}
