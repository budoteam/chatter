import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MCPServerConfig.name) private var servers: [MCPServerConfig]

    @State private var apiKey = ""
    @State private var savedConfirmation = false
    @State private var editingServer: MCPServerConfig?
    @State private var showingNewServer = false

    var body: some View {
        Form {
            apiKeySection
            mcpSection
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
            serverEditor(server)
        }
        .sheet(isPresented: $showingNewServer) {
            serverEditor(nil)
        }
    }

    /// On macOS the editor renders its own SheetHeader — a NavigationStack
    /// toolbar in a sheet shifts the main window's content down on dismiss.
    @ViewBuilder
    private func serverEditor(_ server: MCPServerConfig?) -> some View {
        #if os(macOS)
        MCPServerEditorView(server: server)
            .frame(minWidth: 480, minHeight: 520)
        #else
        NavigationStack { MCPServerEditorView(server: server) }
        #endif
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
                    .foregroundStyle(.green).font(.caption)
            }
            // Live connection status so a bad key (401 etc.) is visible here.
            if env.isLoadingModels {
                Label("Checking key…", systemImage: "hourglass")
                    .foregroundStyle(.secondary).font(.caption)
            } else if let error = env.modelLoadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            } else if !env.models.isEmpty {
                Label("Connected — \(env.models.count) models available", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
            }
        } header: {
            Text("Ollama Cloud")
        } footer: {
            Text("Create a key at ollama.com → Settings → API keys. Stored securely in your keychain and synced via iCloud Keychain.")
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
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
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

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: "1.0")
        } footer: {
            Text("Chatter — LLM chat with MCP tools, powered by Ollama Cloud.")
        }
    }

    // MARK: - Actions

    private func saveKey() {
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
            AppLogger.ui.error("Save API key failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func clearKey() {
        KeychainService.deleteAPIKey()
        apiKey = ""
        env.refreshAPIKeyState()
        env.models = []
    }

    private func deleteServers(_ offsets: IndexSet) {
        offsets.map { servers[$0] }.forEach(deleteServer)
    }

    private func deleteServer(_ server: MCPServerConfig) {
        Task { await env.mcp.disconnect(serverID: server.id) }
        context.delete(server)
        try? context.save()
    }
}
