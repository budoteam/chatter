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
            agentEditor(agent)
        }
        .sheet(isPresented: $showingNewAgent) {
            agentEditor(nil)
        }
    }

    /// On macOS the editor renders its own SheetHeader — a NavigationStack
    /// toolbar in a sheet shifts the main window's content down on dismiss.
    @ViewBuilder
    private func agentEditor(_ agent: Agent?) -> some View {
        #if os(macOS)
        AgentEditorView(agent: agent)
            .frame(minWidth: 500, minHeight: 620)
        #else
        NavigationStack { AgentEditorView(agent: agent) }
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
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(agent.modelId.isEmpty ? "No model" : agent.modelId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !agent.systemPrompt.isEmpty {
                Text(agent.systemPrompt)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            Button { startChat(agent) } label: {
                Label("New Chat", systemImage: "plus.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { editingAgent = agent }
        .contextMenu {
            Button("New Chat") { startChat(agent) }
            Button("Edit…") { editingAgent = agent }
            if agents.count > 1 {
                Divider()
                Button("Delete", role: .destructive) { delete(agent) }
            }
        }
    }

    private var newAgentCard: some View {
        Button { showingNewAgent = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("New Agent")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func startChat(_ agent: Agent) {
        let session = SessionFactory.create(in: context, agent: agent, models: env.models)
        env.openChat(session)
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
        try? context.save()
    }
}
