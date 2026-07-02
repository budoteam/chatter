import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var showSettings: Bool

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Agent.createdAt) private var agents: [Agent]
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

    @State private var editingAgent: Agent?
    @State private var showingNewAgent = false

    var body: some View {
        List(selection: selectionBinding) {
            agentsSection
            sessionsSection
        }
        .listStyle(.sidebar)
        .navigationTitle("Chatter")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startNewSession(agent: defaultAgent)
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
            }
            #if !os(macOS)
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            #endif
        }
        .sheet(item: $editingAgent) { agent in
            NavigationStack { AgentEditorView(agent: agent) }
        }
        .sheet(isPresented: $showingNewAgent) {
            NavigationStack { AgentEditorView(agent: nil) }
        }
    }

    // MARK: - Agents

    private var agentsSection: some View {
        Section {
            ForEach(agents) { agent in
                Button { startNewSession(agent: agent) } label: {
                    HStack(spacing: 10) {
                        AgentBadge(symbol: agent.iconSymbol, color: agent.color, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.name).font(.subheadline.weight(.medium))
                            if !agent.modelId.isEmpty {
                                Text(agent.modelId)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit") { editingAgent = agent }
                    Button("New Chat") { startNewSession(agent: agent) }
                    if agents.count > 1 {
                        Button("Delete", role: .destructive) { delete(agent) }
                    }
                }
            }
        } header: {
            HStack {
                Text("Agents")
                Spacer()
                Button { showingNewAgent = true } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        ForEach(SessionGroup.grouped(sessions), id: \.title) { group in
            Section(group.title) {
                ForEach(group.sessions) { session in
                    SessionRow(session: session)
                        .tag(session)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(session) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    // MARK: - Selection

    private var selectionBinding: Binding<ChatSession?> {
        Binding(get: { env.selectedSession }, set: { env.selectedSession = $0 })
    }

    private var defaultAgent: Agent? {
        env.selectedSession?.agent ?? agents.first(where: \.isDefault) ?? agents.first
    }

    // MARK: - Actions

    private func startNewSession(agent: Agent?) {
        let session = SessionFactory.create(in: context, agent: agent, models: env.models)
        env.selectedSession = session
    }

    private func delete(_ session: ChatSession) {
        if env.selectedSession == session { env.selectedSession = nil }
        context.delete(session)
        try? context.save()
    }

    private func delete(_ agent: Agent) {
        context.delete(agent)
        try? context.save()
    }
}

private struct SessionRow: View {
    let session: ChatSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.agent?.iconSymbol ?? "bubble.left")
                .font(.caption)
                .foregroundStyle(session.agent?.color ?? Theme.accent)
                .frame(width: 18)
            Text(session.title.isEmpty ? "New Chat" : session.title)
                .lineLimit(1)
            Spacer()
        }
    }
}

/// Groups sessions into Today / Yesterday / Previous 7 Days / Older.
private struct SessionGroup {
    let title: String
    let sessions: [ChatSession]

    static func grouped(_ sessions: [ChatSession]) -> [SessionGroup] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, [ChatSession])] = [
            ("Today", []), ("Yesterday", []), ("Previous 7 Days", []), ("Older", []),
        ]
        for session in sessions {
            if cal.isDateInToday(session.updatedAt) {
                buckets[0].1.append(session)
            } else if cal.isDateInYesterday(session.updatedAt) {
                buckets[1].1.append(session)
            } else if let days = cal.dateComponents([.day], from: session.updatedAt, to: now).day,
                      days < 7 {
                buckets[2].1.append(session)
            } else {
                buckets[3].1.append(session)
            }
        }
        return buckets.filter { !$0.1.isEmpty }.map { SessionGroup(title: $0.0, sessions: $0.1) }
    }
}
