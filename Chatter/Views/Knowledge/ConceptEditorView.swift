import SwiftUI
import SwiftData

/// Edit one OKF document: concept id (path), the known frontmatter fields,
/// and the markdown body. Reserved documents (index/log) expose only path and
/// body; custom frontmatter keys are shown read-only and preserved verbatim.
struct ConceptEditorView: View {
    @Bindable var concept: KnowledgeConcept

    @Environment(\.modelContext) private var context

    @State private var pathDraft = ""

    var body: some View {
        Form {
            Section {
                TextField("Concept ID", text: $pathDraft)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .font(.body.monospaced())
                    .onSubmit(commitPath)
                if let issue = pathIssue {
                    Text(issue).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Path")
            } footer: {
                Text("Bundle-relative path without “.md”, e.g. tables/users. Exports as \(pathDraft.isEmpty ? "…" : pathDraft).md")
                    .font(.caption2)
            }

            if concept.kind == .concept {
                frontmatterSection
                customFieldsSection
            }

            Section(concept.kind == .concept ? "Body (Markdown)" : "Contents (Markdown)") {
                TextEditor(text: $concept.body)
                    .font(.body.monospaced())
                    .frame(minHeight: 220)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(concept.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { pathDraft = concept.path }
        .onDisappear {
            commitPath()
            concept.updatedAt = .now
            concept.bundle?.updatedAt = .now
            try? context.save()
        }
    }

    // MARK: - Frontmatter

    private var frontmatterSection: some View {
        Section {
            TextField("Type", text: $concept.typeName)
            if concept.typeName.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("OKF requires a non-empty type (e.g. note, table, playbook).")
                    .font(.caption).foregroundStyle(.red)
            }
            TextField("Title", text: optional($concept.title))
            TextField("Description", text: optional($concept.summary), axis: .vertical)
                .lineLimit(1...4)
            TextField("Resource URI", text: optional($concept.resource))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            TextField("Tags (comma-separated)", text: tagsBinding)
            HStack {
                TextField("Timestamp (ISO 8601)", text: optional($concept.timestampRaw))
                    .font(.body.monospaced())
                Button("Now") {
                    concept.timestampRaw = KnowledgeConcept.currentTimestampString()
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("Frontmatter")
        }
    }

    private var customFieldsSection: some View {
        Group {
            let extras = concept.extraFields
            if !extras.isEmpty {
                Section {
                    DisclosureGroup("Custom Fields (\(extras.count))") {
                        Text(extras.map(\.rawBlock).joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Frontmatter keys Chatter doesn’t model. Preserved verbatim on export.")
                        .font(.caption2)
                }
            }
        }
    }

    // MARK: - Path validation

    private var pathIssue: String? {
        let trimmed = pathDraft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Path must not be empty." }
        if trimmed.hasPrefix("/") || trimmed.hasSuffix("/") || trimmed.contains("//") {
            return "Use a relative path like folder/concept."
        }
        if trimmed.hasSuffix(".md") { return "Omit the .md suffix." }
        if trimmed != concept.path,
           concept.bundle?.concept(atPath: trimmed) != nil {
            return "Another document already uses this path."
        }
        return nil
    }

    private func commitPath() {
        if pathIssue != nil {
            pathDraft = concept.path
            return
        }
        let trimmed = pathDraft.trimmingCharacters(in: .whitespaces)
        guard trimmed != concept.path else { return }
        concept.path = trimmed
        // Reserved names switch the document's role, per the OKF spec.
        let fileName = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        concept.kind = KnowledgeDocKind.forFileName(fileName + ".md")
        // A document renamed away from index/log gains frontmatter on export;
        // make sure it carries a valid (non-empty) type.
        if concept.kind == .concept,
           concept.typeName.trimmingCharacters(in: .whitespaces).isEmpty {
            concept.typeName = "note"
        }
    }

    // MARK: - Bindings

    private func optional(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private var tagsBinding: Binding<String> {
        Binding(
            get: { concept.tags.joined(separator: ", ") },
            set: { text in
                concept.tags = text
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}
