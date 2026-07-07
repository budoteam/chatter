import SwiftUI
import SwiftData

/// The persistent memory of one agent: view, edit, and delete the entries the
/// agent saved about the user. Writing new entries is the agent's job (via
/// the memory tools); this sheet exists for transparency and cleanup.
struct AgentMemoriesSheet: View {
    let agent: Agent

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MemoryEntry.updatedAt, order: .reverse) private var allEntries: [MemoryEntry]

    private var entries: [MemoryEntry] {
        allEntries.filter { $0.agentID == agent.id }
    }

    var body: some View {
        #if os(macOS)
        content
            // ContentUnavailableView only takes its ideal size on macOS;
            // without this the header+content unit centers in the sheet,
            // leaving a gap above the header.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: "Memories") {
                    EmptyView()
                } trailing: {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(minWidth: 440, minHeight: 400)
        #else
        NavigationStack {
            content
                .navigationTitle("Memories")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #endif
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
                            .font(.caption2).foregroundStyle(.secondary)
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
                entry.content = newValue
                entry.updatedAt = Date()
                try? context.save()
            }
        )
    }

    private func delete(at offsets: IndexSet) {
        let entries = entries
        for index in offsets {
            context.delete(entries[index])
        }
        try? context.save()
    }
}
