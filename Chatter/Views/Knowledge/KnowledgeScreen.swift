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
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { openBundle = bundle }
        .contextMenu {
            Button("Open") { openBundle = bundle }
            Divider()
            Button("Delete", role: .destructive) { delete(bundle) }
        }
    }

    private var addCard: some View {
        Menu {
            Button("New Bundle") { createBundle() }
            Button("Import OKF Folder…") { showingImporter = true }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("Add Knowledge")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
    }

    // MARK: - Actions

    private func createBundle() {
        let bundle = KnowledgeBundle(name: "New Bundle")
        context.insert(bundle)
        try? context.save()
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
        try? context.save()
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let report = try KnowledgeTransfer.importBundle(from: url, into: context)
                importReport = report.alertText
            } catch {
                importReport = "Import failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            importReport = "Import failed: \(error.localizedDescription)"
        }
    }
}
