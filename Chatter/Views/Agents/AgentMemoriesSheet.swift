import SwiftUI
import SwiftData

/// The persistent memory of one agent: view, edit, and delete the entries the
/// agent saved about the user. Writing new entries is the agent's job (via
/// the memory tools); this sheet exists for transparency and cleanup.
struct AgentMemoriesSheet: View {
    let agent: Agent

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// Scoped to this agent: an unfiltered query would load every agent's
    /// memories into the view and re-render on any memory write.
    @Query private var entries: [MemoryEntry]
    /// Entries edited since the sheet opened — only those get a fresh
    /// `updatedAt` (and the save) when the sheet closes.
    @State private var dirtyIDs: Set<UUID> = []

    init(agent: Agent) {
        self.agent = agent
        let agentID = agent.id
        _entries = Query(
            filter: #Predicate { $0.agentID == agentID },
            sort: \MemoryEntry.updatedAt,
            order: .reverse
        )
    }

    var body: some View {
        EditorSheet(
            title: "Memories",
            minWidth: 440, minHeight: 400,
            trailing: {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        ) {
            content
        }
        .onDisappear(perform: saveDrafts)
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            ContentUnavailableView(
                "No memories yet",
                systemImage: "brain",
                description: Text("The agent saves durable facts here on its own while you chat.")
            )
        } else {
            List {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Memory", text: binding(for: entry), axis: .vertical)
                            .lineLimit(1...6)
                        Text(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(Theme.Typography.font(.caption)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete(perform: delete)
            }
        }
    }

    private func binding(for entry: MemoryEntry) -> Binding<String> {
        Binding(
            get: { entry.content },
            set: { newValue in
                // In-memory only while typing: a context.save() per keystroke
                // triggered a CloudKit export per character, and bumping
                // updatedAt re-sorted the row out from under the cursor.
                // Persisted once when the sheet closes.
                entry.content = newValue
                dirtyIDs.insert(entry.id)
            }
        )
    }

    private func saveDrafts() {
        guard !dirtyIDs.isEmpty else { return }
        for entry in entries where dirtyIDs.contains(entry.id) {
            entry.updatedAt = .now
        }
        dirtyIDs.removeAll()
        context.saveOrLog()
    }

    private func delete(at offsets: IndexSet) {
        let entries = entries
        for index in offsets {
            context.delete(entries[index])
        }
        context.saveOrLog()
    }
}
