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
    @State private var command = ""
    @State private var argsText = ""
    @State private var enabled = true
    @State private var showingDeleteConfirmation = false

    /// Transports offered here (stdio: unsandboxed macOS only).
    private var availableTransports: [MCPTransportKind] {
        MCPTransportKind.stdioAvailable ? MCPTransportKind.allCases : [.sse, .http]
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $name)
                Picker("Transport", selection: $transport) {
                    ForEach(availableTransports) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                Toggle("Enabled", isOn: $enabled)
            }

            if transport.isRemote {
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
            } else {
                Section {
                    TextField("/usr/local/bin/mcp-server", text: $command)
                        .autocorrectionDisabled()
                    TextField("Arguments (space-separated)", text: $argsText)
                        .autocorrectionDisabled()
                } header: {
                    Text("Command")
                } footer: {
                    Text("Launched as a local subprocess. The app must be able to spawn processes (macOS, sandbox off).")
                }
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
        #if os(iOS)
        .navigationTitle(server == nil ? "New Server" : "Edit Server")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!isValid)
            }
        }
        #else
        // No NavigationStack/toolbar in macOS sheets — see SheetHeader.
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: server == nil ? "New Server" : "Edit Server") {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } trailing: {
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        #endif
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

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return transport.isRemote
            ? !url.trimmingCharacters(in: .whitespaces).isEmpty
            : !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() {
        guard let server else { return }
        name = server.name
        transport = server.transport
        url = server.url
        headerKey = server.headerKey
        headerValue = server.headerValue
        command = server.command
        argsText = server.args.joined(separator: " ")
        enabled = server.enabled
    }

    private func save() {
        let target = server ?? MCPServerConfig()
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.transport = transport
        target.url = url.trimmingCharacters(in: .whitespaces)
        target.headerKey = headerKey.trimmingCharacters(in: .whitespaces)
        target.headerValue = headerValue
        target.command = command.trimmingCharacters(in: .whitespaces)
        target.args = argsText.split(separator: " ").map(String.init)
        target.enabled = enabled
        if server == nil { context.insert(target) }
        try? context.save()

        // Reconnect to reflect the change.
        let id = target.id
        Task {
            await env.mcp.disconnect(serverID: id)
            if target.enabled { await env.mcp.connect(target) }
        }
        dismiss()
    }

    private func delete() {
        guard let server else { return }
        let id = server.id
        Task { await env.mcp.disconnect(serverID: id) }
        context.delete(server)
        try? context.save()
        dismiss()
    }
}
