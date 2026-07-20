import SwiftUI
import SwiftData

/// Session list + entry point for new chats. All configuration (agents, MCP
/// servers, API key) syncs in from the user's other devices — this view only
/// surfaces sync state, it has nothing to configure itself.
struct WatchRootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]
    @Query(sort: \Agent.createdAt) private var agents: [Agent]
    @Query private var mcpServers: [MCPServerConfig]

    @State private var showAgentPicker = false
    /// Session created from the agent picker, pushed programmatically.
    @State private var pushedSession: ChatSession?

    var body: some View {
        NavigationStack {
            List {
                if !env.hasAPIKey {
                    Label("Waiting for the Ollama API key to sync via iCloud Keychain…", systemImage: "key")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    NavigationLink(value: session) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .lineLimit(2)
                            if let agent = session.agent {
                                Label(agent.name, systemImage: agent.iconSymbol)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteSessions)
            }
            .navigationTitle("Chatter")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAgentPicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(agents.isEmpty)
                }
            }
            .sheet(isPresented: $showAgentPicker) {
                NavigationStack {
                    List(agents) { agent in
                        Button {
                            startChat(with: agent)
                        } label: {
                            Label(agent.name, systemImage: agent.iconSymbol)
                                .foregroundStyle(agent.color)
                        }
                    }
                    .navigationTitle("New Chat")
                }
            }
            .navigationDestination(for: ChatSession.self) { session in
                WatchChatView(session: session)
            }
            .navigationDestination(item: $pushedSession) { session in
                WatchChatView(session: session)
            }
        }
        .task {
            env.refreshAPIKeyState()
            await env.refreshModels()
            await env.mcp.syncConnections(configs: mcpServers.filter(\.enabled))
        }
    }

    private func startChat(with agent: Agent) {
        showAgentPicker = false
        // Same model rule as SessionFactory on iOS/macOS: the agent's model,
        // else the first available one.
        let modelId = agent.modelId.isEmpty ? (env.models.first?.name ?? "") : agent.modelId
        let session = ChatSession(agent: agent, modelId: modelId)
        context.insert(session)
        context.saveOrLog()
        pushedSession = session
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            let session = sessions[index]
            Task {
                // Never delete underneath a running turn (engine mutates the
                // session's messages until teardown completes).
                await env.cancelTurnAndWait(for: session)
                context.delete(session)
                context.saveOrLog()
            }
        }
    }
}
