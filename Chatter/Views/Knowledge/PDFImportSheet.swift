import SwiftUI
import SwiftData

/// Options + progress for a PDF → OKF import run. Idle: pick the conversion
/// model and start; running: progress with cancel. Reports back through the
/// presenting view's existing import alert.
struct PDFImportSheet: View {
    let urls: [URL]
    let bundle: KnowledgeBundle
    let onFinish: (KnowledgeTransfer.ImportReport) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Agent.createdAt) private var agents: [Agent]

    @State private var job = PDFImportJob()
    @State private var selectedModel = ""

    private var canConvert: Bool { env.hasAPIKey && !env.models.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                switch job.phase {
                case .idle:
                    optionsContent
                case .running(let current, let total, let fileName):
                    runningContent(current: current, total: total, fileName: fileName)
                case .finished:
                    // Momentary: onChange fires onFinish which dismisses.
                    ProgressView()
                }
            }
            .formStyle(.grouped)
            #if os(iOS)
            .navigationTitle("Import PDFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .idle = job.phase {
                        Button("Start") { start() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            #endif
        }
        #if os(macOS)
        // No NavigationStack/toolbar chrome in macOS sheets — see SheetHeader.
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: "Import PDFs") {
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
            } trailing: {
                if case .idle = job.phase {
                    Button("Start") { start() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        #endif
        .interactiveDismissDisabled(isRunning)
        .onAppear(perform: seedModel)
        // Models may load after the sheet appears; re-seed while still unset.
        .onChange(of: env.models.map(\.name)) { seedModel() }
        .onChange(of: job.phase) { _, phase in
            if phase == .finished { onFinish(job.report) }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }

    private var isRunning: Bool {
        if case .running = job.phase { return true }
        return false
    }

    // MARK: - States

    private var optionsContent: some View {
        Group {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(urls.count) PDF\(urls.count == 1 ? "" : "s") selected")
                            .font(Theme.Typography.font(.title2))
                        Text("Import into “\(bundle.name)”")
                            .font(Theme.Typography.font(.caption)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                if urls.count == 1 {
                    fileRow(urls[0])
                } else {
                    DisclosureGroup("Files") {
                        ForEach(urls, id: \.self) { url in
                            fileRow(url)
                        }
                    }
                }
            }

            Section {
                if canConvert {
                    Picker("Model", selection: $selectedModel) {
                        // Keep the seeded model selectable even if the live
                        // list doesn't contain it (same as AgentEditorView).
                        if !selectedModel.isEmpty,
                           !env.models.contains(where: { $0.name == selectedModel }) {
                            Text(selectedModel).tag(selectedModel)
                        }
                        ForEach(env.models) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                } else {
                    Label {
                        Text("No API key or models available — PDFs will be imported as raw text without AI conversion.")
                            .font(Theme.Typography.font(.caption)).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Conversion")
            } footer: {
                if canConvert {
                    Text("The extracted text is sent to the selected model, which cleans it up and splits it into concepts. PDFs without a text layer are skipped (no OCR yet).")
                }
            }
        }
    }

    private func fileRow(_ url: URL) -> some View {
        Label {
            Text(url.deletingPathExtension().lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
        }
        .font(Theme.Typography.font(.body))
    }

    private func runningContent(current: Int, total: Int, fileName: String) -> some View {
        Section {
            HStack(spacing: 14) {
                // Indeterminate: converting one PDF is the slow step, and a
                // determinate bar over the file count would sit still for it.
                ProgressView()
                    .controlSize(.regular)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Converting \(current) of \(total)")
                        .font(Theme.Typography.font(.bodyEmphasis))
                    Text(fileName)
                        .font(Theme.Typography.font(.caption)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text("Imported so far: \(job.report.imported) concepts")
                        .font(Theme.Typography.font(.caption)).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - Actions

    private func seedModel() {
        guard selectedModel.isEmpty else { return }
        selectedModel = SessionFactory.defaultModel(
            agent: SessionFactory.defaultAgent(in: agents), models: env.models
        )
    }

    private func cancel() {
        switch job.phase {
        case .running: job.cancel()
        default: onFinish(job.report)
        }
    }

    private func start() {
        job.start(
            urls: urls,
            bundle: bundle,
            context: context,
            ollama: env.ollama,
            model: canConvert && !selectedModel.isEmpty ? selectedModel : nil
        )
    }
}
