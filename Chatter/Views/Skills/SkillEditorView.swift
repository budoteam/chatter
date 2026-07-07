import SwiftUI
import SwiftData

/// Create or edit a `Skill` in the shared pool: slug name, one-line summary,
/// and the markdown body agents load via skills__read.
struct SkillEditorView: View {
    /// nil → creating a new skill.
    let skill: Skill?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var summary = ""
    @State private var content = ""

    var body: some View {
        Form {
            Section {
                TextField("Name (e.g. weekly-report)", text: $name)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                TextField("One-line summary", text: $summary)
            } header: {
                Text("Skill")
            } footer: {
                Text("The name is how agents address the skill; the summary is shown in their skill index.")
            }

            Section {
                // TextEditor, not TextField(axis: .vertical) — see
                // AgentEditorView's system-prompt field.
                TextEditor(text: $content)
                    .font(.body.monospaced())
                    .frame(minHeight: 220)
            } header: {
                Text("Content")
            } footer: {
                Text("Step-by-step markdown instructions. Agents usually write skills themselves — edit here to review or refine them.")
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle(skill == nil ? "New Skill" : "Edit Skill")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
        #else
        // No NavigationStack/toolbar in macOS sheets — see SheetHeader.
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: skill == nil ? "New Skill" : "Edit Skill") {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } trailing: {
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        #endif
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        !SkillToolProvider.slugify(name).isEmpty
    }

    private func load() {
        guard let skill else { return }
        name = skill.name
        summary = skill.summary
        content = skill.content
    }

    private func save() {
        let target = skill ?? Skill()
        target.name = SkillToolProvider.slugify(name)
        target.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        target.content = content
        target.updatedAt = Date()
        if skill == nil {
            context.insert(target)
        }
        try? context.save()
        dismiss()
    }
}
