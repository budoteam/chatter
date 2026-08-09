import SwiftUI
import SwiftData

/// Detail-column overview of all agents ("Bots"). Tapping a card edits the
/// agent; each card carries a quick "New Chat" action. Opened from the sidebar's
/// bottom "Agents" button.
struct AgentsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Agent.createdAt) private var agents: [Agent]

    @State private var editingAgent: Agent?
    @State private var showingNewAgent = false

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(agents) { agent in
                    card(for: agent)
                }
                newAgentCard
            }
            .padding(Theme.Spacing.lg)
        }
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItem {
                Button { showingNewAgent = true } label: {
                    Label("New Agent", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingAgent) { agent in
            AgentEditorView(agent: agent)
        }
        .sheet(isPresented: $showingNewAgent) {
            AgentEditorView(agent: nil)
        }
        #if DEBUG
        // Screenshot demo: open the editor for the first (default) agent so
        // the capture shows the model selection of a real agent.
        .onAppear {
            if ScreenshotDemo.screen == "agent-editor", editingAgent == nil {
                editingAgent = agents.first
            }
        }
        #endif
    }

    // MARK: - Cards

    private func card(for agent: Agent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                AgentBadge(symbol: agent.iconSymbol, color: agent.color, size: 40)
                Spacer(minLength: 0)
                if agent.isDefault {
                    Text("Default")
                        .font(Theme.Typography.font(.caption).weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(Theme.Typography.font(.title2))
                    .lineLimit(1)
                Text(agent.modelId.isEmpty ? "No model" : agent.modelId)
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !agent.systemPrompt.isEmpty {
                Text(agent.systemPrompt)
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            Button { startChat(agent) } label: {
                Label("New Chat", systemImage: "plus.bubble")
                    .font(Theme.Typography.font(.caption).weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .overviewCardStyle()
        .onTapGesture { editingAgent = agent }
        .contextMenu {
            Button("New Chat") { startChat(agent) }
            Button("Edit…") { editingAgent = agent }
            Button("Duplicate") { duplicate(agent) }
            if agents.count > 1 {
                Divider()
                Button("Delete", role: .destructive) { delete(agent) }
            }
        }
    }

    private var newAgentCard: some View {
        AddEntityCard(title: "New Agent") { showingNewAgent = true }
    }

    // MARK: - Actions

    private func startChat(_ agent: Agent) {
        let session = SessionFactory.create(in: context, agent: agent, models: env.models)
        env.openChat(session)
    }

    private func duplicate(_ agent: Agent) {
        let copy = Agent(
            name: agent.name + " Copy",
            systemPrompt: agent.systemPrompt,
            modelId: agent.modelId,
            temperature: agent.temperature,
            iconSymbol: agent.iconSymbol,
            colorHex: agent.colorHex,
            mcpServerIDs: agent.mcpServerIDs,
            knowledgeBundleIDs: agent.knowledgeBundleIDs,
            skillIDs: agent.skillIDs,
            memoryEnabled: agent.memoryEnabled,
            skillAuthoringEnabled: agent.skillAuthoringEnabled,
            webAccessEnabled: agent.webAccessEnabled
            // isDefault deliberately not copied — exactly one default agent.
        )
        copy.alternateModelIds = agent.alternateModelIds
        copy.thinkingMode = agent.thinkingMode
        context.insert(copy)
        context.saveOrLog()
    }

    private func delete(_ agent: Agent) {
        // Memories reference the agent by ID (no relationship), so they must
        // be cleaned up explicitly.
        let agentID = agent.id
        let memories = (try? context.fetch(FetchDescriptor<MemoryEntry>())) ?? []
        for entry in memories where entry.agentID == agentID {
            context.delete(entry)
        }
        context.delete(agent)
        context.saveOrLog()
    }
}
