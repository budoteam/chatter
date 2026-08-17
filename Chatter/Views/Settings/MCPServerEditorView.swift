import SwiftUI
import SwiftData

/// Create or edit an MCP server connection.
struct MCPServerEditorView: View {
    let server: MCPServerConfig?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var transport: MCPTransportKind = .sse
    @State private var url = ""
    @State private var headerKey = ""
    @State private var headerValue = ""
    @State private var enabled = true
    @State private var showingDeleteConfirmation = false

    var body: some View {
        EditorSheet(
            title: server == nil ? "New Server" : "Edit Server",
            minWidth: 480, minHeight: 520,
            leading: {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            },
            trailing: {
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        ) {
            formContent
        }
        .onAppear(perform: load)
        .confirmationDialog(
            "Delete this MCP server?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the server configuration. This can't be undone.")
        }
    }

    private var formContent: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $name)
                Picker("Transport", selection: $transport) {
                    ForEach(MCPTransportKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                Toggle("Enabled", isOn: $enabled)
            }

            Section {
                TextField("https://server.example.com/mcp", text: $url)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            } header: {
                Text("Connection")
            } footer: {
                Text("Streamable HTTP is the modern MCP transport. Choose SSE (legacy) for servers exposing a /sse endpoint, e.g. supergateway or mcp-proxy bridges.")
            }

            Section("Auth Header (optional)") {
                TextField("Header (e.g. Authorization)", text: $headerKey)
                    .autocorrectionDisabled()
                SecureField("Value (e.g. Bearer …)", text: $headerValue)
            }

            if server != nil {
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete Server", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() {
        guard let server else { return }
        name = server.name
        transport = server.transport
        url = server.url
        headerKey = server.headerKey
        headerValue = server.headerValue
        enabled = server.enabled
    }

    private func save() {
        let target = server ?? MCPServerConfig()
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.transport = transport
        target.url = url.trimmingCharacters(in: .whitespaces)
        target.headerKey = headerKey.trimmingCharacters(in: .whitespaces)
        target.headerValue = headerValue
        target.enabled = enabled
        if server == nil { context.insert(target) }
        context.saveOrLog()

        // Reconnect to reflect the change. `remove` (not `disconnect`) also
        // drops the cached tools — stale, after URL/transport may have changed.
        let id = target.id
        Task {
            await env.mcp.remove(serverID: id)
            if target.enabled { await env.mcp.connect(target) }
        }
        dismiss()
    }

    private func delete() {
        guard let server else { return }
        let id = server.id
        Task { await env.mcp.remove(serverID: id) }
        context.delete(server)
        context.saveOrLog()
        dismiss()
    }
}
