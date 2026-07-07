import SwiftUI
import SwiftData

/// Detail-column list of the shared skill pool. Skills are mostly authored by
/// agents themselves (skills__create); this screen is for reviewing, editing,
/// and deleting them. Opened from the sidebar's bottom "Skills" button.
struct SkillsScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Skill.name) private var skills: [Skill]

    @State private var editingSkill: Skill?
    @State private var showingNewSkill = false

    var body: some View {
        Group {
            if skills.isEmpty {
                ContentUnavailableView(
                    "No skills yet",
                    systemImage: "wand.and.stars",
                    description: Text("Skills are reusable procedures your agents can follow — and write themselves when authoring is enabled.")
                )
            } else {
                List {
                    ForEach(skills) { skill in
                        Button { editingSkill = skill } label: {
                            row(for: skill)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) { delete(skill) }
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("Skills")
        .toolbar {
            ToolbarItem {
                Button { showingNewSkill = true } label: {
                    Label("New Skill", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingSkill) { skill in
            skillEditor(skill)
        }
        .sheet(isPresented: $showingNewSkill) {
            skillEditor(nil)
        }
    }

    private func row(for skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(skill.name)
                .font(.body.weight(.medium))
            if !skill.summary.isEmpty {
                Text(skill.summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// On macOS the editor renders its own SheetHeader — a NavigationStack
    /// toolbar in a sheet shifts the main window's content down on dismiss.
    @ViewBuilder
    private func skillEditor(_ skill: Skill?) -> some View {
        #if os(macOS)
        SkillEditorView(skill: skill)
            .frame(minWidth: 480, minHeight: 480)
        #else
        NavigationStack { SkillEditorView(skill: skill) }
        #endif
    }

    // MARK: - Delete

    private func delete(at offsets: IndexSet) {
        for index in offsets { delete(skills[index]) }
    }

    private func delete(_ skill: Skill) {
        // Agents reference skills by ID; strip the reference everywhere so
        // their editors don't carry dangling toggles.
        let agents = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        for agent in agents where agent.skillIDs.contains(skill.id) {
            agent.skillIDs.removeAll { $0 == skill.id }
        }
        context.delete(skill)
        try? context.save()
    }
}
