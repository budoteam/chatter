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
    @State private var showPDFImporter = false
    @State private var pdfImportRequest: PDFImportRequest?
    /// Held until the PDF sheet has fully dismissed, then shown — presenting
    /// the alert in the same transaction as the dismiss can drop it on iOS.
    @State private var pendingPDFReport: KnowledgeTransfer.ImportReport?

    /// Identifiable wrapper so the PDF sheet uses `.sheet(item:)`.
    private struct PDFImportRequest: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section("Bundle") {
                    TextField("Name", text: $bundle.name)
                    TextField("Notes", text: $bundle.about, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section {
                    if tree.isEmpty {
                        ContentUnavailableView {
                            Label("No Documents", systemImage: "books.vertical")
                        } description: {
                            Text("Create a concept, or import an OKF folder or PDFs.")
                        }
                    }
                    OutlineGroup(tree, children: \.children) { node in
                        if let concept = node.concept {
                            NavigationLink(value: concept) {
                                conceptRow(node.name, concept: concept)
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) { delete(concept) }
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) { delete(concept) }
                            }
                        } else {
                            Label {
                                Text(node.name)
                            } icon: {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Theme.accent.opacity(0.7))
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Documents")
                        Spacer()
                        if bundle.conceptCount > 0 {
                            Text("\(bundle.conceptCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        addConcept()
                    } label: {
                        actionRow("New Concept", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)

                    Button {
                        showPDFImporter = true
                    } label: {
                        actionRow("Import PDFs…", systemImage: "doc.badge.plus")
                    }

                    Button {
                        showImporter = true
                    } label: {
                        actionRow("Import OKF Folder (Merge)…", systemImage: "folder.badge.plus")
                    }

                    Button {
                        exportDocument = OKFBundleDocument(
                            root: KnowledgeTransfer.exportWrapper(for: bundle)
                        )
                        showExporter = true
                    } label: {
                        actionRow("Export Bundle…", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .formStyle(.grouped)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            #if os(iOS)
            .navigationTitle(bundle.name)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: KnowledgeConcept.self) { concept in
                ConceptEditorView(concept: concept)
            }
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            #endif
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
        // Attached to the NavigationStack, NOT the List: a second fileImporter
        // on the same node as the folder importer can silently break on iOS.
        .fileImporter(
            isPresented: $showPDFImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                pdfImportRequest = PDFImportRequest(urls: urls)
            case .failure(let error):
                importReport = "Import failed: \(error.localizedDescription)"
            }
        }
        .sheet(item: $pdfImportRequest, onDismiss: showPendingPDFReport) { request in
            PDFImportSheet(urls: request.urls, bundle: bundle) { report in
                pendingPDFReport = report
                pdfImportRequest = nil  // dismiss; report shown in onDismiss
            }
        }
        #if os(macOS)
        // No NavigationStack/toolbar chrome in macOS sheets — see SheetHeader.
        // Attached outside the stack so Done stays visible while drilled into
        // a concept.
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: bundle.name) {
                EmptyView()
            } trailing: {
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 560, minHeight: 620)
        #endif
    }

    private func finish() {
        bundle.updatedAt = .now
        try? context.save()
        dismiss()
    }

    // MARK: - Rows

    private func conceptRow(_ name: String, concept: KnowledgeConcept) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: concept.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(concept.displayTitle)
                    .lineLimit(1)
                Text(subtitle(for: concept))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 1)
        }
        .padding(.vertical, 2)
    }

    private func subtitle(for concept: KnowledgeConcept) -> String {
        var parts: [String] = []
        switch concept.kind {
        case .concept: parts.append(concept.typeName)
        case .index: parts.append("index")
        case .log: parts.append("log")
        }
        if let summary = concept.summary, !summary.isEmpty {
            parts.append(summary)
        } else if !concept.tags.isEmpty {
            parts.append(concept.tags.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// Uniform accent-tinted row for the action buttons below the tree.
    private func actionRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
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

    /// Plain box, deliberately not observed: mutating it inside `body` is
    /// legal and doesn't re-trigger rendering — memoizes the folder tree
    /// across renders.
    private final class TreeCache {
        var fingerprint = ""
        var nodes: [TreeNode] = []
    }
    @State private var treeCache = TreeCache()

    private var tree: [TreeNode] {
        // Rebuild only when the concept paths change. Name/notes keystrokes
        // re-render the whole Form (bindings into the observed bundle), and
        // `tree` is read twice per body — without memoization every keystroke
        // paid for two recursive tree builds.
        let concepts = bundle.orderedConcepts
        let fingerprint = concepts.map(\.path).joined(separator: "\n")
        if fingerprint != treeCache.fingerprint {
            treeCache.nodes = nodes(
                for: concepts.map { ($0.path.split(separator: "/").map(String.init), $0) },
                prefix: ""
            )
            treeCache.fingerprint = fingerprint
        }
        return treeCache.nodes
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
                importReport = report.alertText
            } catch {
                importReport = "Import failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            importReport = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Shown after the PDF sheet has fully dismissed (see `pendingPDFReport`).
    private func showPendingPDFReport() {
        guard let report = pendingPDFReport else { return }
        pendingPDFReport = nil
        if report.imported > 0 || report.skipped > 0 || !report.warnings.isEmpty {
            importReport = report.alertText
        }
    }
}
