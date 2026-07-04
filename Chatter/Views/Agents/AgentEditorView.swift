import SwiftUI
import SwiftData

/// Create or edit an `Agent`: name, look, system prompt, model, temperature,
/// and which MCP servers it may use.
struct AgentEditorView: View {
    /// nil → creating a new agent.
    let agent: Agent?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MCPServerConfig.name) private var servers: [MCPServerConfig]
    @Query(sort: \KnowledgeBundle.name) private var knowledgeBundles: [KnowledgeBundle]

    @State private var name = ""
    @State private var systemPrompt = ""
    @State private var modelId = ""
    @State private var temperature = 0.7
    @State private var iconSymbol = "sparkles"
    @State private var colorHex = "6C5CE7"
    @State private var selectedServerIDs: Set<UUID> = []
    @State private var selectedBundleIDs: Set<UUID> = []

    private let icons = ["sparkles", "brain", "bolt.fill", "wand.and.stars", "cpu",
                         "message.fill", "book.fill", "chevron.left.forwardslash.chevron.right",
                         "paintbrush.fill", "graduationcap.fill", "leaf.fill", "flame.fill"]
    private let palette = ["6C5CE7", "4F86FF", "E15CC0", "00B894", "E17055", "0984E3",
                           "6D4C41", "D63031", "F39C12", "2D3436"]

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $name)
                iconPicker
                colorPicker
            }

            Section("Model") {
                Picker("Model", selection: $modelId) {
                    Text("Select…").tag("")
                    // Keep the stored model selectable even if the live list
                    // doesn't (yet) contain it, so the picker doesn't reset.
                    if !modelId.isEmpty, !env.models.contains(where: { $0.name == modelId }) {
                        Text(modelId).tag(modelId)
                    }
                    ForEach(env.models) { model in
                        Text(model.name).tag(model.name)
                    }
                }
                if env.models.isEmpty {
                    Text("No models loaded. Add your API key in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.1f", temperature)).foregroundStyle(.secondary)
                    }
                    Slider(value: $temperature, in: 0...1, step: 0.1)
                }
            }

            Section("System Prompt") {
                TextField("Instructions for this agent…", text: $systemPrompt, axis: .vertical)
                    .lineLimit(4...12)
            }

            Section("MCP Servers") {
                if servers.isEmpty {
                    Text("No MCP servers configured. Add some in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(servers) { server in
                    Toggle(isOn: membership(of: server.id, in: $selectedServerIDs)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name)
                            Text(server.transport.label)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Knowledge") {
                if knowledgeBundles.isEmpty {
                    Text("No knowledge bundles yet. Add some from the sidebar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(knowledgeBundles) { bundle in
                    Toggle(isOn: membership(of: bundle.id, in: $selectedBundleIDs)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bundle.name)
                            Text("\(bundle.conceptCount) concepts")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(agent == nil ? "New Agent" : "Edit Agent")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: load)
    }

    private var iconPicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 10) {
            ForEach(icons, id: \.self) { symbol in
                Button { iconSymbol = symbol } label: {
                    Image(systemName: symbol)
                        .frame(width: 36, height: 36)
                        .background(
                            iconSymbol == symbol ? Color(hex: colorHex).opacity(0.2) : Theme.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(iconSymbol == symbol ? Color(hex: colorHex) : .clear, lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private var colorPicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 10) {
            ForEach(palette, id: \.self) { hex in
                Button { colorHex = hex } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle().stroke(.primary, lineWidth: colorHex == hex ? 2 : 0)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func membership(of id: UUID, in set: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { on in
                if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
            }
        )
    }

    private func load() {
        guard let agent else {
            modelId = env.models.first?.name ?? ""
            return
        }
        name = agent.name
        systemPrompt = agent.systemPrompt
        modelId = agent.modelId
        temperature = agent.temperature
        iconSymbol = agent.iconSymbol
        colorHex = agent.colorHex
        selectedServerIDs = Set(agent.mcpServerIDs)
        selectedBundleIDs = Set(agent.knowledgeBundleIDs)
    }

    private func save() {
        let target = agent ?? Agent()
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.systemPrompt = systemPrompt
        target.modelId = modelId
        target.temperature = temperature
        target.iconSymbol = iconSymbol
        target.colorHex = colorHex
        target.mcpServerIDs = Array(selectedServerIDs)
        target.knowledgeBundleIDs = Array(selectedBundleIDs)
        if agent == nil {
            context.insert(target)
        }
        try? context.save()
        dismiss()
    }
}
