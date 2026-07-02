import SwiftUI

/// Bottom input pill: multiline text field, model chip, and send/stop button.
struct ComposerView: View {
    @Bindable var viewModel: ChatViewModel
    let session: ChatSession
    let onSend: () -> Void

    @Environment(AppEnvironment.self) private var env
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            modelChip
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Chatter…", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.vertical, 10)
                    .padding(.leading, 16)
                    .focused($focused)
                    .onSubmit(onSend)

                sendButton
                    .padding(4)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 1)
            )
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    private var modelChip: some View {
        HStack {
            Menu {
                if env.models.isEmpty {
                    Text("No models — check Settings")
                }
                ForEach(env.models) { model in
                    Button {
                        session.modelId = model.name
                    } label: {
                        if session.modelId == model.name {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu").font(.caption2)
                    Text(session.modelId.isEmpty ? "Select model" : session.modelId)
                        .font(.caption)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surfaceRaised, in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: viewModel.isSending ? "stop.fill" : "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    Group {
                        if viewModel.isSending {
                            Circle().fill(Color.secondary)
                        } else if viewModel.canSend {
                            Circle().fill(Theme.brandGradient)
                        } else {
                            Circle().fill(Color.secondary.opacity(0.4))
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canSend && !viewModel.isSending)
        .keyboardShortcut(.return, modifiers: .command)
    }
}
