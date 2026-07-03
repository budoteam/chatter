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
        .environment(\.defaultMinListRowHeight, 36)
        .safeAreaInset(edge: .top, spacing: 0) { newChatButton }
        .navigationTitle("Chatter")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        #endif
        .sheet(item: $editingAgent) { agent in
            NavigationStack { AgentEditorView(agent: agent) }
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 620)
                #endif
        }
        .sheet(isPresented: $showingNewAgent) {
            NavigationStack { AgentEditorView(agent: nil) }
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 620)
                #endif
        }
    }

    // MARK: - New Chat

    private var newChatButton: some View {
        Button { startNewSession(agent: defaultAgent) } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.bubble.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("New Chat")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Theme.brandGradient, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)  // ⌘N comes from the app-level command
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: - Agents

    private var agentsSection: some View {
        Section {
            ForEach(agents) { agent in
                Button { startNewSession(agent: agent) } label: {
                    HStack(spacing: 10) {
                        AgentBadge(symbol: agent.iconSymbol, color: agent.color, size: 26)
                        Text(agent.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("New Chat") { startNewSession(agent: agent) }
                    Button("Edit…") { editingAgent = agent }
                    if agents.count > 1 {
                        Divider()
                        Button("Delete", role: .destructive) { delete(agent) }
                    }
                }
            }

            Button { showingNewAgent = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 26)
                        .background(Theme.accent.opacity(0.12), in: Circle())
                    Text("New Agent")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            sectionHeader("Agents")
        }
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        ForEach(SessionGroup.grouped(sessions), id: \.title) { group in
            Section {
                ForEach(group.sessions) { session in
                    Text(session.title.isEmpty ? "New Chat" : session.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .tag(session)
                        .contextMenu {
                            Button("Delete", role: .destructive) { delete(session) }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(session) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            } header: {
                sectionHeader(group.title)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
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
