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

    @State private var exportDocument: SkillFileDocument?
    @State private var showExporter = false

    var body: some View {
        EditorSheet(
            title: skill == nil ? "New Skill" : "Edit Skill",
            minWidth: 480, minHeight: 480,
            leading: {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            },
            secondary: {
                Button("Export…") { export() }
                    .disabled(!canSave)
            },
            trailing: {
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        ) {
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
                        .font(Theme.Typography.font(.mono))
                        .frame(minHeight: 220)
                } header: {
                    Text("Content")
                } footer: {
                    Text("Step-by-step markdown instructions. Agents usually write skills themselves — edit here to review or refine them.")
                }
            }
            .formStyle(.grouped)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: SkillTransfer.markdownType,
            defaultFilename: SkillToolProvider.slugify(name)
        ) { _ in }
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        !SkillToolProvider.slugify(name).isEmpty
    }

    /// Exports the current form state (not the stored row), so unsaved edits
    /// land in the file.
    private func export() {
        exportDocument = SkillFileDocument(text: SkillCodec.serialize(
            name: SkillToolProvider.slugify(name),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            content: content
        ))
        showExporter = true
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
        context.saveOrLog()
        dismiss()
    }
}
