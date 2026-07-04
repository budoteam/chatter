import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Browse and manage one OKF knowledge bundle: folder tree of its concepts,
/// creation, and folder-based import (merge) / export.
struct KnowledgeBundleView: View {
    @Bindable var bundle: KnowledgeBundle

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var path: [KnowledgeConcept] = []
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument: OKFBundleDocument?
    @State private var importReport: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Bundle") {
                    TextField("Name", text: $bundle.name)
                    TextField("Notes", text: $bundle.about, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section("Documents") {
                    if tree.isEmpty {
                        Text("No documents yet. Create a concept or import an OKF folder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    OutlineGroup(tree, children: \.children) { node in
                        if let concept = node.concept {
                            NavigationLink(value: concept) {
                                conceptRow(node.name, concept: concept)
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) { delete(concept) }
                            }
                        } else {
                            Label(node.name, systemImage: "folder")
                        }
                    }

                    Button {
                        addConcept()
                    } label: {
                        Label("New Concept", systemImage: "plus")
                    }
                }
            }
            .navigationTitle(bundle.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: KnowledgeConcept.self) { concept in
                ConceptEditorView(concept: concept)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        bundle.updatedAt = .now
                        try? context.save()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Button("Import Folder (Merge)…") { showImporter = true }
                        Button("Export Bundle…") {
                            exportDocument = OKFBundleDocument(
                                root: KnowledgeTransfer.exportWrapper(for: bundle)
                            )
                            showExporter = true
                        }
                    } label: {
                        Label("Import/Export", systemImage: "square.and.arrow.up.on.square")
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.folder]
            ) { result in
                handleImport(result)
            }
            .fileExporter(
                isPresented: $showExporter,
                document: exportDocument,
                contentType: .folder,
                defaultFilename: bundle.name
            ) { result in
                if case .failure(let error) = result {
                    importReport = "Export failed: \(error.localizedDescription)"
                }
            }
            .alert(
                "Knowledge Import",
                isPresented: Binding(
                    get: { importReport != nil },
                    set: { if !$0 { importReport = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importReport ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
    }

    // MARK: - Rows

    private func conceptRow(_ name: String, concept: KnowledgeConcept) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: concept.kind))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(concept.displayTitle)
                if concept.kind == .concept {
                    Text(concept.typeName)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func icon(for kind: KnowledgeDocKind) -> String {
        switch kind {
        case .concept: return "doc.text"
        case .index: return "list.bullet.rectangle"
        case .log: return "clock.arrow.circlepath"
        }
    }

    // MARK: - Tree

    private struct TreeNode: Identifiable {
        let id: String
        let name: String
        /// nil for leaves; OutlineGroup treats nil as "no disclosure".
        var children: [TreeNode]?
        var concept: KnowledgeConcept?
    }

    private var tree: [TreeNode] {
        nodes(for: bundle.orderedConcepts.map { ($0.path.split(separator: "/").map(String.init), $0) }, prefix: "")
    }

    private func nodes(
        for entries: [(components: [String], concept: KnowledgeConcept)], prefix: String
    ) -> [TreeNode] {
        var folders: [String: [(components: [String], concept: KnowledgeConcept)]] = [:]
        var leaves: [TreeNode] = []

        for entry in entries {
            guard let head = entry.components.first else { continue }
            if entry.components.count == 1 {
                leaves.append(TreeNode(
                    id: prefix + head, name: head, children: nil, concept: entry.concept
                ))
            } else {
                folders[head, default: []].append(
                    (Array(entry.components.dropFirst()), entry.concept)
                )
            }
        }

        let folderNodes = folders.keys.sorted().map { name in
            TreeNode(
                id: prefix + name + "/",
                name: name,
                children: nodes(for: folders[name] ?? [], prefix: prefix + name + "/"),
                concept: nil
            )
        }
        return folderNodes + leaves.sorted { $0.name < $1.name }
    }

    // MARK: - Actions

    private func addConcept() {
        var candidate = "new-concept"
        var counter = 2
        while bundle.concept(atPath: candidate) != nil {
            candidate = "new-concept-\(counter)"
            counter += 1
        }
        let concept = KnowledgeConcept(path: candidate)
        concept.bundle = bundle
        context.insert(concept)
        bundle.updatedAt = .now
        try? context.save()
        path.append(concept)
    }

    private func delete(_ concept: KnowledgeConcept) {
        context.delete(concept)
        bundle.updatedAt = .now
        try? context.save()
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let report = try KnowledgeTransfer.importBundle(
                    from: url, into: context, mergingInto: bundle
                )
                var text = report.summary
                if !report.warnings.isEmpty {
                    text += "\n\nWarnings:\n" + report.warnings.prefix(8).joined(separator: "\n")
                    if report.warnings.count > 8 {
                        text += "\n(\(report.warnings.count - 8) more)"
                    }
                }
                importReport = text
            } catch {
                importReport = "Import failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            importReport = "Import failed: \(error.localizedDescription)"
        }
    }
}
