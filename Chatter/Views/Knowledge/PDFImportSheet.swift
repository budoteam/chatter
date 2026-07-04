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
            .navigationTitle("Import PDFs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        switch job.phase {
                        case .running: job.cancel()
                        default: onFinish(job.report)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .idle = job.phase {
                        Button("Start") { start() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isRunning)
        .onAppear(perform: seedModel)
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
                Text("Import \(urls.count) PDF\(urls.count == 1 ? "" : "s") into “\(bundle.name)”")
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
                    Text("The extracted text is sent to the selected model, which cleans it up and splits it into concepts. PDFs without a text layer are skipped (no OCR yet).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No API key or models available — PDFs will be imported as raw text without AI conversion.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Conversion")
            }
        }
    }

    private func runningContent(current: Int, total: Int, fileName: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: Double(current - 1), total: Double(total))
                Text("Converting \(current) of \(total) — \(fileName)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Imported so far: \(job.report.imported) concepts")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Actions

    private func seedModel() {
        guard selectedModel.isEmpty else { return }
        let defaultAgent = agents.first(where: \.isDefault) ?? agents.first
        if let model = defaultAgent?.modelId, !model.isEmpty {
            selectedModel = model
        } else {
            selectedModel = env.models.first?.name ?? ""
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
