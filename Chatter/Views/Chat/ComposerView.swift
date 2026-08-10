import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    @State private var showFilePicker = false
    #if os(macOS)
    @State private var pasteMonitor: Any?
    #endif
    #if os(iOS)
    /// Inserting "\n" for Shift+Return also fires the field's onSubmit
    /// (SwiftUI detects submit via newline insertion); this swallows that one.
    @State private var suppressNextSubmit = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.pendingImages.isEmpty {
                thumbnailStrip
            }
            if viewModel.imageLimitHit, !viewModel.pendingImages.isEmpty {
                Text("Some images were skipped — attachments are limited to 700 KB per message so the chat keeps syncing via iCloud.")
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }

            TextField(placeholder, text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .padding(.horizontal, 4)
                #if os(macOS)
                // Return sends; Shift+Return inserts a line break at the cursor.
                // Plain .ignored doesn't work for Shift+Return (the field editor
                // treats it as submit/select-all instead of a newline), so we
                // forward AppKit's explicit "insert newline" action.
                .onKeyPress(phases: .down) { press in
                    guard press.key == .return else { return .ignored }
                    if press.modifiers.contains(.shift) {
                        NSApp.sendAction(
                            #selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)),
                            to: nil, from: nil
                        )
                        return .handled
                    }
                    performSend()
                    return .handled
                }
                #else
                // Software-keyboard Return submits (onSubmit); on hardware
                // keyboards (iPad) Shift+Return inserts a line break instead
                // of also submitting.
                .onKeyPress(phases: .down) { press in
                    // Cmd-V attaches an image clipboard (UIKit text paste
                    // can't handle images); a text clipboard falls through
                    // to the field's normal paste. iOS has no onPasteCommand.
                    if press.modifiers.contains(.command), press.characters == "v",
                       viewModel.canAttachImages, UIPasteboard.general.hasImages {
                        let providers = UIPasteboard.general.itemProviders
                        Task {
                            viewModel.addBase64Images(await ImageAttachmentProcessor.makeBase64JPEGs(from: providers))
                        }
                        return .handled
                    }
                    if press.key == .return, press.modifiers.contains(.shift) {
                        suppressNextSubmit = true
                        insertNewlineAtCursor()
                        return .handled
                    }
                    // Any other key invalidates a stale suppress so a real
                    // Return is never swallowed.
                    suppressNextSubmit = false
                    return .ignored
                }
                .onSubmit {
                    if suppressNextSubmit {
                        suppressNextSubmit = false
                    } else {
                        performSend()
                    }
                }
                #endif

            HStack(spacing: 8) {
                photoButton
                fileButton
                #if os(iOS)
                if viewModel.canAttachImages {
                    PasteImageControl { providers in
                        Task {
                            viewModel.addBase64Images(await ImageAttachmentProcessor.makeBase64JPEGs(from: providers))
                        }
                    }
                }
                #endif
                agentMenu
                if let agent = session.agent, agent.allModelIds.count > 1 {
                    modelMenu
                }
                Spacer(minLength: 8)
                sendButton
            }
        }
        .task(id: "\(currentModel)|\(env.visionModel)") {
            viewModel.canAttachImages = await env.canAttachImages(for: currentModel)
        }
        // A fresh chat should be ready to type into immediately. ChatView is
        // re-created per session (.id(session.id)), so this fires once per
        // newly opened chat; the deferred hop is needed because focusing
        // during the appearance transaction is ignored on iOS.
        .onAppear {
            guard (session.messages ?? []).isEmpty else { return }
            Task { @MainActor in focused = true }
        }
        #if os(macOS)
        .onAppear {
            let focus = $focused
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let mods = event.modifierFlags
                // keyCode 9 = ANSI V — layout-unabhängig (Dvorak & Co.).
                guard event.keyCode == 9,
                      mods.contains(.command), !mods.contains(.option), !mods.contains(.control),
                      focus.wrappedValue, viewModel.canAttachImages,
                      let base64s = ImageAttachmentProcessor.base64JPEGsFromPasteboard()
                else { return event }
                viewModel.addBase64Images(base64s)
                return nil
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        }
        #endif
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPickedImages(items) }
        }
        #if os(macOS)
        // Only .image is claimed: text paste and Finder file-copy paste keep
        // falling through to the text field (a file copy inserts its path).
        .onPasteCommand(of: [.image]) { providers in
            guard viewModel.canAttachImages else { return }
            Task {
                viewModel.addBase64Images(await ImageAttachmentProcessor.makeBase64JPEGs(from: providers))
            }
        }
        #endif
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await loadFileURLs(urls) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.surface)
                .elevated(Theme.Elevation.level1)
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
        if !session.modelOverride.isEmpty { return session.modelOverride }
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
                .foregroundStyle(viewModel.canAttachImages ? Color.secondary : Color.secondary.opacity(0.35))
                .frame(width: 30, height: 30)
                .background(Theme.surfaceRaised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canAttachImages)
        .help(viewModel.canAttachImages
            ? "Attach images"
            : "This model doesn’t support images")
        // Icon-only button: .help is no VoiceOver label.
        .accessibilityLabel(Text(viewModel.canAttachImages
            ? "Attach images"
            : "This model doesn’t support images"))
    }

    private var fileButton: some View {
        Button { showFilePicker = true } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(viewModel.canAttachImages ? Color.secondary : Color.secondary.opacity(0.35))
                .frame(width: 30, height: 30)
                .background(Theme.surfaceRaised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canAttachImages)
        .help(viewModel.canAttachImages
            ? "Attach image files"
            : "This model doesn’t support images")
        .accessibilityLabel(Text(viewModel.canAttachImages
            ? "Attach image files"
            : "This model doesn’t support images"))
    }

    private func loadPickedImages(_ items: [PhotosPickerItem]) async {
        var base64s: [String] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let base64 = ImageAttachmentProcessor.makeBase64JPEG(from: data) {
                base64s.append(base64)
            }
        }
        viewModel.addBase64Images(base64s)
        photoItems = []
    }

    private func loadFileURLs(_ urls: [URL]) async {
        var base64s: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url),
               let base64 = ImageAttachmentProcessor.makeBase64JPEG(from: data) {
                base64s.append(base64)
            }
        }
        viewModel.addBase64Images(base64s)
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
            .font(Theme.Typography.font(.caption).weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Theme.surfaceRaised, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    private func agentTitle(_ agent: Agent) -> String {
        agent.modelId.isEmpty ? agent.name : "\(agent.name) — \(agent.modelId)"
    }

    private func select(_ agent: Agent) {
        session.modelOverride = ""
        session.agent = agent
        if !agent.modelId.isEmpty {
            session.modelId = agent.modelId
        }
    }

    // MARK: - Model selector (quick-switch within the agent's models)

    private var modelMenu: some View {
        Menu {
            ForEach(session.agent?.allModelIds ?? [], id: \.self) { model in
                Button { selectModel(model) } label: {
                    if model == currentModel {
                        Label(model, systemImage: "checkmark")
                    } else {
                        Text(model)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 9, weight: .semibold))
                Text(currentModel)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(Theme.Typography.font(.caption).weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Theme.surfaceRaised, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    private func selectModel(_ model: String) {
        // Choosing the agent's primary model clears the pin instead, so later
        // agent model edits keep propagating to this chat.
        session.modelOverride = model == session.agent?.modelId ? "" : model
    }

    // MARK: - Send / stop

    #if os(iOS)
    /// Inserts "\n" at the cursor WITHOUT `insertText` — SwiftUI treats an
    /// inserted newline as Return and fires onSubmit. `UITextInput.replace`
    /// is the programmatic-edit path and bypasses submit detection.
    private func insertNewlineAtCursor() {
        if let input = UIResponder.currentFirst as? UITextInput,
           let range = input.selectedTextRange {
            input.replace(range, withText: "\n")
        } else {
            viewModel.inputText += "\n"
        }
    }
    #endif

    /// Sends (or stops) and keeps the input field focused so the user can
    /// type the next message right away — button clicks (macOS) and the send
    /// itself would otherwise drop focus.
    private func performSend() {
        onSend()
        Task { @MainActor in focused = true }
    }

    private var isSending: Bool { env.isSending(session) }

    private var sendButton: some View {
        Button(action: performSend) {
            Image(systemName: isSending ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(sendFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.hasDraft && !isSending)
        .keyboardShortcut(.return, modifiers: .command)
        .animation(Theme.Motion.Easing.standard, value: isSending)
        .accessibilityLabel(Text(isSending ? "Stop" : "Send"))
    }

    private var sendFill: AnyShapeStyle {
        if isSending {
            AnyShapeStyle(Color.secondary.opacity(0.85))
        } else if viewModel.hasDraft {
            AnyShapeStyle(Theme.accentFill)
        } else {
            AnyShapeStyle(Color.secondary.opacity(0.35))
        }
    }
}

#if os(iOS)
private extension UIResponder {
    @MainActor static weak var _currentFirst: UIResponder?

    /// The current first responder, found by bouncing an action down the
    /// responder chain (UIKit has no public accessor). Used to insert a line
    /// break at the cursor for hardware-keyboard Shift+Return.
    @MainActor static var currentFirst: UIResponder? {
        _currentFirst = nil
        UIApplication.shared.sendAction(#selector(captureFirst), to: nil, from: nil, for: nil)
        return _currentFirst
    }

    @MainActor @objc private func captureFirst() {
        UIResponder._currentFirst = self
    }
}

/// System paste button (iOS 16+): reads the clipboard WITHOUT the
/// paste-permission alert, because the tap goes through Apple's own UI.
/// It tracks the pasteboard itself and is enabled only when the clipboard
/// holds content matching the coordinator's `pasteConfiguration` (images).
private struct PasteImageControl: UIViewRepresentable {
    /// Called with the clipboard's item providers on tap.
    let onPaste: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPaste: onPaste) }

    func makeUIView(context: Context) -> UIPasteControl {
        let config = UIPasteControl.Configuration()
        config.displayMode = .iconOnly
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor(Theme.surfaceRaised)
        config.baseForegroundColor = UIColor(Color.secondary)
        let control = UIPasteControl(configuration: config)
        control.target = context.coordinator
        return control
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {
        context.coordinator.onPaste = onPaste
    }

    final class Coordinator: NSObject, UIPasteConfigurationSupporting {
        var onPaste: ([NSItemProvider]) -> Void

        init(onPaste: @escaping ([NSItemProvider]) -> Void) { self.onPaste = onPaste }

        var pasteConfiguration: UIPasteConfiguration? =
            UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier])

        func paste(itemProviders: [NSItemProvider]) { onPaste(itemProviders) }
    }
}
#endif
