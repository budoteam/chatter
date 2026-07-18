import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var showSettings: Bool

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Agent.createdAt) private var agents: [Agent]
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

    var body: some View {
        List(selection: selectionBinding) {
            if sessions.isEmpty {
                emptyState
            } else {
                sessionsSection
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 34)
        #if os(iOS)
        // The default grouped sidebar background looks heavy on iOS; use the
        // app canvas instead so the sidebar matches the detail column.
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        #endif
        .safeAreaInset(edge: .top, spacing: 0) { newChatButton }
        .safeAreaInset(edge: .bottom, spacing: 0) { navButtons }
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
            .shadow(color: Theme.accent.opacity(0.28), radius: 8, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)  // ⌘N comes from the app-level command
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }

    // MARK: - Bottom navigation (Agents / Knowledge / Skills)

    private var navButtons: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)
            HStack(spacing: 8) {
                navButton(title: "Agents", systemImage: "person.2.fill", screen: .agents)
                navButton(title: "Knowledge", systemImage: "books.vertical.fill", screen: .knowledge)
                navButton(title: "Skills", systemImage: "wand.and.stars", screen: .skills)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func navButton(title: String, systemImage: String, screen: MainScreen) -> some View {
        let isActive = env.mainScreen == screen
        return Button { env.showScreen(screen) } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(isActive ? Theme.accent : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                isActive ? AnyShapeStyle(Theme.accent.opacity(0.12)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sessions

    /// Plain box, deliberately not observed: mutating it inside `body` is
    /// legal and doesn't re-trigger rendering — memoizes the date bucketing
    /// so selection-change re-renders don't redo Calendar math per session.
    private final class GroupCache {
        var key = 0
        var groups: [SessionGroup] = []
    }
    @State private var groupCache = GroupCache()

    private var groupedSessions: [SessionGroup] {
        var hasher = Hasher()
        // Buckets shift at midnight even if no session changed.
        hasher.combine(Calendar.current.startOfDay(for: .now))
        for session in sessions {
            hasher.combine(session.id)
            hasher.combine(session.updatedAt)
        }
        let key = hasher.finalize()
        if key != groupCache.key || groupCache.groups.isEmpty {
            groupCache.groups = SessionGroup.grouped(sessions)
            groupCache.key = key
        }
        return groupCache.groups
    }

    private var sessionsSection: some View {
        ForEach(groupedSessions, id: \.title) { group in
            Section {
                ForEach(group.sessions) { session in
                    sessionRow(session)
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

    private func sessionRow(_ session: ChatSession) -> some View {
        HStack(spacing: 9) {
            // Tiny agent-colored bubble so chats are attributable at a glance.
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 10))
                .foregroundStyle(
                    (session.agent?.color ?? Theme.accent).opacity(0.75)
                )
            Text(session.title.isEmpty ? "New Chat" : session.title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("No chats yet")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Start a conversation with New Chat.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    // MARK: - Selection

    /// The list highlights a session only while the chat screen is active; when
    /// the Agents/Knowledge overview is showing, nothing is selected. Selecting
    /// a row switches back to the chat screen.
    private var selectionBinding: Binding<ChatSession?> {
        Binding(
            get: { env.mainScreen == .chat ? env.selectedSession : nil },
            set: { if let session = $0 { env.openChat(session) } else { env.selectedSession = nil } }
        )
    }

    private var defaultAgent: Agent? {
        env.selectedSession?.agent ?? SessionFactory.defaultAgent(in: agents)
    }

    // MARK: - Actions

    private func startNewSession(agent: Agent?) {
        let session = SessionFactory.create(in: context, agent: agent, models: env.models)
        env.openChat(session)
    }

    private func delete(_ session: ChatSession) {
        if env.selectedSession == session { env.selectedSession = nil }
        Task { @MainActor in
            // A turn may still be streaming into this session — wait for its
            // teardown saves before deleting the models it writes to.
            await env.cancelTurnAndWait(for: session)
            context.delete(session)
            context.saveOrLog()
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
