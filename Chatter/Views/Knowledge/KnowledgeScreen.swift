import SwiftUI
import SwiftData

/// Detail-column overview of all knowledge bundles ("Knowledge-DBs"). Tapping a
/// card opens the bundle. Opened from the sidebar's bottom "Knowledge" button.
struct KnowledgeScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \KnowledgeBundle.name) private var bundles: [KnowledgeBundle]

    @State private var openBundle: KnowledgeBundle?
    @State private var showingImporter = false
    @State private var importReport: String?
    @State private var isImporting = false

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(bundles) { bundle in
                    card(for: bundle)
                }
                addCard
            }
            .padding(Theme.Spacing.lg)
        }
        .navigationTitle("Knowledge")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Bundle") { createBundle() }
                    Button("Import OKF Folder…") { showingImporter = true }
                } label: {
                    Label("Add Knowledge", systemImage: "plus")
                }
            }
        }
        .sheet(item: $openBundle) { bundle in
            KnowledgeBundleView(bundle: bundle)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.folder]
        ) { result in
            handleImport(result)
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
        // Block interaction while the folder is parsed off-actor and merged.
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

    // MARK: - Cards

    private func card(for bundle: KnowledgeBundle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.name)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(bundle.conceptCount) concepts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Label("Open", systemImage: "arrow.up.right.square")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        .overviewCardStyle()
        .onTapGesture { openBundle = bundle }
        .contextMenu {
            Button("Open") { openBundle = bundle }
            Divider()
            Button("Delete", role: .destructive) { delete(bundle) }
        }
    }

    private var addCard: some View {
        AddEntityCard(title: "Add Knowledge", menuContent: {
            Button("New Bundle") { createBundle() }
            Button("Import OKF Folder…") { showingImporter = true }
        })
    }

    // MARK: - Actions

    private func createBundle() {
        let bundle = KnowledgeBundle(name: "New Bundle")
        context.insert(bundle)
        context.saveOrLog()
        openBundle = bundle
    }

    private func delete(_ bundle: KnowledgeBundle) {
        if openBundle == bundle { openBundle = nil }
        // Scrub the soft references so agents don't keep dangling bundle IDs
        // (they'd silently lose their knowledge tools with no UI trace).
        let allAgents = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        for agent in allAgents where agent.knowledgeBundleIDs.contains(bundle.id) {
            agent.knowledgeBundleIDs.removeAll { $0 == bundle.id }
        }
        context.delete(bundle)
        context.saveOrLog()
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            // Parse off-actor, then apply on the main actor — large bundles
            // would otherwise freeze the UI in the fileImporter callback.
            isImporting = true
            Task { @MainActor in
                defer { isImporting = false }
                do {
                    let parsed = try await KnowledgeTransfer.parseBundle(from: url)
                    importReport = KnowledgeTransfer.applyImport(parsed, into: context).alertText
                } catch {
                    importReport = "Import failed: \(error.localizedDescription)"
                }
            }
        case .failure(let error):
            importReport = "Import failed: \(error.localizedDescription)"
        }
    }
}
