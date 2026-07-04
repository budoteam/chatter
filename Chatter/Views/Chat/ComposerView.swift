import SwiftUI
import SwiftData
import PhotosUI

/// Bottom input card: multiline text on top, agent selector + send button in a
/// control row inside the same rounded surface (Gemini-style). The model is
/// defined by the selected agent.
struct ComposerView: View {
    @Bindable var viewModel: ChatViewModel
    let session: ChatSession
    let onSend: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Query(sort: \Agent.createdAt) private var agents: [Agent]
    @FocusState private var focused: Bool
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var supportsVision = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.pendingImages.isEmpty {
                thumbnailStrip
            }

            TextField(placeholder, text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(onSend)
                .padding(.horizontal, 4)

            HStack(spacing: 8) {
                photoButton
                agentMenu
                Spacer(minLength: 8)
                sendButton
            }
        }
        .task(id: currentModel) {
            supportsVision = await env.supportsVision(currentModel)
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPickedImages(items) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.07), radius: 16, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        )
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.md)
    }

    private var placeholder: String {
        if let name = session.agent?.name, !name.isEmpty { return "Message \(name)…" }
        return "Message Chatter…"
    }

    /// The model that will actually run this turn (agent's model, else session).
    private var currentModel: String {
        if let m = session.agent?.modelId, !m.isEmpty { return m }
        return session.modelId
    }

    // MARK: - Image attachments

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.pendingImages) { attachment in
                    AttachmentThumbnail(base64: attachment.base64) {
                        viewModel.pendingImages.removeAll { $0.id == attachment.id }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
    }

    private var photoButton: some View {
        PhotosPicker(
            selection: $photoItems,
            maxSelectionCount: 4,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(supportsVision ? Color.secondary : Color.secondary.opacity(0.35))
                .frame(width: 30, height: 30)
                .background(Theme.surfaceRaised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!supportsVision)
        .help(supportsVision
            ? "Attach images"
            : "This model doesn’t support images")
    }

    private func loadPickedImages(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let base64 = ImageAttachmentProcessor.makeBase64JPEG(from: data) else { continue }
            viewModel.pendingImages.append(ImageAttachment(base64: base64))
        }
        photoItems = []
    }

    // MARK: - Agent selector (the agent defines the model)

    private var agentMenu: some View {
        Menu {
            ForEach(agents) { agent in
                Button { select(agent) } label: {
                    if session.agent == agent {
                        Label(agentTitle(agent), systemImage: "checkmark")
                    } else {
                        Text(agentTitle(agent))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let agent = session.agent {
                    AgentBadge(symbol: agent.iconSymbol, color: agent.color, size: 16)
                    Text(agent.name)
                        .lineLimit(1)
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Choose agent")
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Theme.surfaceRaised, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .frame(maxWidth: 260, alignment: .leading)
    }

    private func agentTitle(_ agent: Agent) -> String {
        agent.modelId.isEmpty ? agent.name : "\(agent.name) — \(agent.modelId)"
    }

    private func select(_ agent: Agent) {
        session.agent = agent
        if !agent.modelId.isEmpty {
            session.modelId = agent.modelId
        }
    }

    // MARK: - Send / stop

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: viewModel.isSending ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(sendFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canSend && !viewModel.isSending)
        .keyboardShortcut(.return, modifiers: .command)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isSending)
    }

    private var sendFill: AnyShapeStyle {
        if viewModel.isSending {
            AnyShapeStyle(Color.secondary.opacity(0.85))
        } else if viewModel.canSend {
            AnyShapeStyle(Theme.brandGradient)
        } else {
            AnyShapeStyle(Color.secondary.opacity(0.35))
        }
    }
}
