import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Detail-column list of the shared skill pool. Skills are mostly authored by
/// agents themselves (skills__create); this screen is for reviewing, editing,
/// deleting, and moving them across devices (markdown export/import). Opened
/// from the sidebar's bottom "Skills" button.
struct SkillsScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Skill.name) private var skills: [Skill]

    @State private var editingSkill: Skill?
    @State private var showingNewSkill = false

    @State private var exportingSkillDoc: SkillFileDocument?
    @State private var exportingSkillName = ""
    @State private var showSkillExporter = false
    @State private var exportAllDoc: OKFBundleDocument?
    @State private var showFolderExporter = false
    @State private var showImporter = false
    @State private var importReport: String?
    /// The report alert doubles for export failures — the title tracks which
    /// operation produced the report.
    @State private var reportTitle = "Skill Import"
    @State private var isImporting = false

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
                            Button("Export…") { export(skill) }
                            Button("Delete", role: .destructive) { delete(skill) }
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        // Attached here, NOT next to the folder exporter below: two
        // exporters/importers on the same node can silently break on iOS.
        .fileExporter(
            isPresented: $showSkillExporter,
            document: exportingSkillDoc,
            contentType: SkillTransfer.markdownType,
            defaultFilename: exportingSkillName
        ) { result in
            if case .failure(let error) = result {
                reportTitle = "Skill Export"
                importReport = "Export failed: \(error.localizedDescription)"
            }
        }
        .navigationTitle("Skills")
        .toolbar {
            ToolbarItem {
                Button { showingNewSkill = true } label: {
                    Label("New Skill", systemImage: "plus")
                }
            }
            ToolbarItem {
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import Skills…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        exportAllDoc = OKFBundleDocument(root: SkillTransfer.exportWrapper(for: skills))
                        showFolderExporter = true
                    } label: {
                        Label("Export All Skills…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(skills.isEmpty)
                } label: {
                    Label("Import/Export", systemImage: "ellipsis.circle")
                }
            }
        }
        .fileExporter(
            isPresented: $showFolderExporter,
            document: exportAllDoc,
            contentType: .folder,
            defaultFilename: "Skills"
        ) { result in
            if case .failure(let error) = result {
                reportTitle = "Skill Export"
                importReport = "Export failed: \(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder, SkillTransfer.markdownType, .plainText],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .alert(
            reportTitle,
            isPresented: Binding(
                get: { importReport != nil },
                set: { if !$0 { importReport = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importReport ?? "")
        }
        .sheet(item: $editingSkill) { skill in
            SkillEditorView(skill: skill)
        }
        .sheet(isPresented: $showingNewSkill) {
            SkillEditorView(skill: nil)
        }
        // Block interaction while the files are parsed off-actor and merged.
        .disabled(isImporting)
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView("Importing…")
                        .padding(Theme.Spacing.md)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
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

    // MARK: - Import / Export

    private func export(_ skill: Skill) {
        exportingSkillDoc = SkillFileDocument(text: SkillTransfer.serializedContents(for: skill))
        exportingSkillName = skill.name
        showSkillExporter = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        reportTitle = "Skill Import"
        switch result {
        case .success(let urls):
            // Parse off-actor, then apply on the main actor — large imports
            // would otherwise freeze the UI in the fileImporter callback.
            isImporting = true
            Task { @MainActor in
                defer { isImporting = false }
                let parsed = await SkillTransfer.parseSkills(from: urls)
                importReport = SkillTransfer.applyImport(parsed, into: context).alertText
            }
        case .failure(let error):
            importReport = "Import failed: \(error.localizedDescription)"
        }
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
        context.saveOrLog()
    }
}
