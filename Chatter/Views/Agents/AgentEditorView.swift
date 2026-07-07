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
    @Query(sort: \Skill.name) private var allSkills: [Skill]

    @State private var name = ""
    @State private var systemPrompt = ""
    @State private var modelId = ""
    @State private var temperature = 0.7
    @State private var iconSymbol = "sparkles"
    @State private var colorHex = "6C5CE7"
    @State private var selectedServerIDs: Set<UUID> = []
    @State private var selectedBundleIDs: Set<UUID> = []
    @State private var webAccess = true
    @State private var thinkingMode: ThinkingMode = .standard
    @State private var supportsThinking = false
    @State private var selectedSkillIDs: Set<UUID> = []
    @State private var skillAuthoring = false
    @State private var memoryEnabled = false
    @State private var showMemories = false

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

            Section {
                Picker("Thinking", selection: $thinkingMode) {
                    ForEach(ThinkingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } header: {
                Text("Reasoning")
            } footer: {
                Text(supportsThinking
                    ? "Controls the model's reasoning trace. Low/Medium/High are for models like gpt-oss that require an effort level."
                    : "The selected model doesn't report thinking support — this setting is ignored.")
            }
            .task(id: modelId) {
                supportsThinking = await env.supports("thinking", model: modelId)
            }

            Section {
                // TextEditor, not TextField(axis: .vertical): the growing
                // TextField misaligns in macOS forms (trailing-aligned, no
                // scrolling) and jumps on newline inside iOS forms. Same
                // pattern as ConceptEditorView's markdown body.
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 140)
            } header: {
                Text("System Prompt")
            } footer: {
                Text("Instructions for this agent.")
            }

            Section {
                Toggle("Web search & page fetch", isOn: $webAccess)
            } header: {
                Text("Web Research")
            } footer: {
                Text("Lets the agent search the web and read pages via Ollama's web search API (uses your API key).")
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

            Section {
                ForEach(allSkills) { skill in
                    Toggle(isOn: membership(of: skill.id, in: $selectedSkillIDs)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(skill.name)
                            if !skill.summary.isEmpty {
                                Text(skill.summary)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Toggle("Can create & edit skills", isOn: $skillAuthoring)
            } header: {
                Text("Skills")
            } footer: {
                Text("Skills are reusable procedures shared across agents. Authoring lets this agent write new skills into the pool.")
            }

            Section {
                Toggle("Persistent memory", isOn: $memoryEnabled)
                if agent != nil, memoryEnabled {
                    Button("Show memories…") { showMemories = true }
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("The agent saves and maintains its own notes about you across chats.")
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
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
        #else
        // No NavigationStack/toolbar in macOS sheets — see SheetHeader.
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: agent == nil ? "New Agent" : "Edit Agent") {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } trailing: {
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        #endif
        .onAppear(perform: load)
        .sheet(isPresented: $showMemories) {
            if let agent {
                AgentMemoriesSheet(agent: agent)
            }
        }
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
        selectedSkillIDs = Set(agent.skillIDs)
        skillAuthoring = agent.skillAuthoringEnabled
        memoryEnabled = agent.memoryEnabled
        webAccess = agent.webAccessEnabled
        thinkingMode = agent.thinkingMode
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
        target.skillIDs = Array(selectedSkillIDs)
        target.skillAuthoringEnabled = skillAuthoring
        target.memoryEnabled = memoryEnabled
        target.webAccessEnabled = webAccess
        target.thinkingMode = thinkingMode
        if agent == nil {
            context.insert(target)
        }
        try? context.save()
        dismiss()
    }
}
