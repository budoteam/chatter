import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MCPServerConfig.name) private var servers: [MCPServerConfig]

    @State private var apiKey = ""
    @State private var savedConfirmation = false
    /// Keychain write failures — saving must not fail silently (log only).
    @State private var keySaveError: String?
    @State private var editingServer: MCPServerConfig?
    @State private var showingNewServer = false

    var body: some View {
        Form {
            apiKeySection
            visionSection
            mcpSection
            syncSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            #if !os(macOS)
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            #endif
        }
        .onAppear { apiKey = KeychainService.loadAPIKey() ?? "" }
        .sheet(item: $editingServer) { server in
            MCPServerEditorView(server: server)
        }
        .sheet(isPresented: $showingNewServer) {
            MCPServerEditorView(server: nil)
        }
    }

    // MARK: - API key

    private var apiKeySection: some View {
        Section {
            SecureField("Ollama API key", text: $apiKey)
            HStack {
                Button("Save Key") { saveKey() }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                if env.hasAPIKey {
                    Spacer()
                    Button("Clear", role: .destructive) { clearKey() }
                }
            }
            if savedConfirmation {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(Theme.Typography.font(.caption))
            }
            if let keySaveError {
                Label(keySaveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(Theme.Typography.font(.caption))
            }
            // Live connection status so a bad key (401 etc.) is visible here.
            if env.isLoadingModels {
                Label("Checking key…", systemImage: "hourglass")
                    .foregroundStyle(.secondary).font(Theme.Typography.font(.caption))
            } else if let error = env.modelLoadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(Theme.Typography.font(.caption))
            } else if !env.models.isEmpty {
                Label("Connected — \(env.models.count) models available", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(Theme.Typography.font(.caption))
            }
        } header: {
            Text("Ollama Cloud")
        } footer: {
            Text("Create a key at ollama.com → Settings → API keys. Stored securely in your keychain and synced via iCloud Keychain.")
        }
    }

    // MARK: - Vision

    private var visionSection: some View {
        Section {
            Picker("Vision model", selection: Binding(
                get: { env.visionModel },
                set: { env.visionModel = $0 }
            )) {
                Text("None").tag("")
                // Keep the stored model selectable even if the live list doesn't
                // (yet) contain it (same pattern as AgentEditorView).
                if !env.visionModel.isEmpty, !env.models.contains(where: { $0.name == env.visionModel }) {
                    Text(env.visionModel).tag(env.visionModel)
                }
                ForEach(env.models) { model in
                    Text(model.name).tag(model.name)
                }
            }
            if env.models.isEmpty {
                Text("No models loaded. Add your API key above.")
                    .font(Theme.Typography.font(.caption)).foregroundStyle(.secondary)
            }
        } header: {
            Text("Vision")
        } footer: {
            Text("Describes attached images when the agent's model can't process images itself. The description is sent to the agent's model as text. Stored on this device only.")
        }
    }

    // MARK: - MCP servers

    private var mcpSection: some View {
        Section {
            if servers.isEmpty {
                Text("No MCP servers yet.").foregroundStyle(.secondary)
            }
            ForEach(servers) { server in
                Button { editingServer = server } label: {
                    HStack(spacing: 10) {
                        statusDot(for: server)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name).foregroundStyle(.primary)
                            Text(subtitle(for: server))
                                .font(Theme.Typography.font(.caption)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(Theme.Typography.font(.caption)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        deleteServer(server)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete(perform: deleteServers)

            Button { showingNewServer = true } label: {
                Label("Add MCP Server", systemImage: "plus")
            }
        } header: {
            Text("MCP Servers")
        } footer: {
            Text("Agents can call tools from the servers you enable for them. HTTP/SSE work on all platforms; stdio (local subprocess) is macOS only.")
        }
    }

    private func statusDot(for server: MCPServerConfig) -> some View {
        let state = env.mcp.states[server.id] ?? .disconnected
        let color: Color = {
            switch state {
            case .connected: return .green
            case .connecting: return .orange
            case .failed: return .red
            case .disconnected: return .gray
            }
        }()
        return Circle().fill(color).frame(width: 9, height: 9)
    }

    private func subtitle(for server: MCPServerConfig) -> String {
        let state = env.mcp.states[server.id] ?? .disconnected
        switch state {
        case .connected(let count): return "\(server.transport.label) · \(count) tools"
        case .connecting: return "Connecting…"
        case .failed(let msg): return "Failed: \(msg)"
        case .disconnected: return server.enabled ? server.transport.label : "Disabled"
        }
    }

    // MARK: - iCloud sync

    private var syncSection: some View {
        Section {
            storeModeRow
            if env.sync.storeMode == .cloudKit {
                syncEventRow(title: "Export", status: env.sync.exports)
                syncEventRow(title: "Import", status: env.sync.imports)
            }
        } header: {
            Text("iCloud Sync")
        } footer: {
            Text("Chats, agents, skills and memories sync via your private iCloud database. Export = this device uploading, import = receiving changes from other devices.")
        }
    }

    @ViewBuilder
    private var storeModeRow: some View {
        switch env.sync.storeMode {
        case .cloudKit:
            Label("iCloud (CloudKit)", systemImage: "icloud")
        case .localOnly:
            Label("Local only — changes do NOT sync. Check the iCloud login on this device.", systemImage: "exclamationmark.icloud.fill")
                .foregroundStyle(.orange)
        case .inMemory:
            Label("In-memory store — data is lost when the app quits.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func syncEventRow(title: String, status: CloudSyncMonitor.EventStatus) -> some View {
        LabeledContent(title) {
            if status.isRunning {
                Label("Running…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            } else if let end = status.endDate {
                if status.succeeded {
                    Label(end.formatted(.relative(presentation: .named)), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(end.formatted(.relative(presentation: .named)), systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            } else {
                Text("No activity yet this session")
                    .foregroundStyle(.secondary)
            }
        }
        .font(Theme.Typography.font(.body))
        if !status.succeeded, let error = status.errorDescription {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(Theme.Typography.font(.caption))
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.appVersion)
        } footer: {
            Text("Chatter — LLM chat with MCP tools, powered by Ollama Cloud.")
        }
    }

    /// "1.4 (20260707.2)" — read from the bundle so it always matches the build.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - Actions

    private func saveKey() {
        keySaveError = nil
        do {
            try KeychainService.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            env.refreshAPIKeyState()
            savedConfirmation = true
            Task {
                await env.refreshModels()
                try? await Task.sleep(for: .seconds(2))
                savedConfirmation = false
            }
        } catch {
            keySaveError = error.localizedDescription
            AppLogger.ui.error("Save API key failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func clearKey() {
        KeychainService.deleteAPIKey()
        apiKey = ""
        keySaveError = nil
        env.refreshAPIKeyState()
        env.models = []
    }

    private func deleteServers(_ offsets: IndexSet) {
        offsets.map { servers[$0] }.forEach(deleteServer)
    }

    private func deleteServer(_ server: MCPServerConfig) {
        Task { await env.mcp.disconnect(serverID: server.id) }
        context.delete(server)
        context.saveOrLog()
    }
}
