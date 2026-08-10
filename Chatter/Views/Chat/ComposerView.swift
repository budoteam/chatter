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
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFilePicker = false
    #if os(macOS)
    @FocusState private var focused: Bool
    @State private var pasteMonitor: Any?
    #else
    /// First-responder state of the UIKit input field (see ComposerTextField).
    @State private var focused = false
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

            #if os(macOS)
            TextField(placeholder, text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .padding(.horizontal, 4)
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
            // A real UITextView so system image paste works (long-press Paste,
            // keyboard paste button, Cmd+V); Return sends, Shift+Return breaks.
            ComposerTextField(
                text: $viewModel.inputText,
                focused: $focused,
                placeholder: placeholder,
                canAttachImages: viewModel.canAttachImages,
                onSubmit: performSend,
                onPasteImages: pasteImages
            )
            .padding(.horizontal, 4)
            #endif

            HStack(spacing: 8) {
                photoButton
                fileButton
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
        // iOS handles image paste inside ComposerTextField — onPasteCommand
        // is explicitly unavailable there despite what Apple's docs claim.
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
    /// Images from the system paste pipeline become attachments; text paste
    /// stays in the field itself.
    private func pasteImages(_ providers: [NSItemProvider]) {
        Task {
            viewModel.addBase64Images(await ImageAttachmentProcessor.makeBase64JPEGs(from: providers))
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
/// Multiline chat input backed by a real UITextView so the system paste
/// pipeline (long-press Paste, the software keyboard's paste button, Cmd+V)
/// works for images: an image clipboard becomes attachments while text
/// paste keeps falling through to the field itself. Return submits;
/// Shift+Return (hardware keyboard) inserts a line break.
private struct ComposerTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let canAttachImages: Bool
    let onSubmit: () -> Void
    let onPasteImages: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.delegate = context.coordinator
        view.onSubmit = onSubmit
        view.onPasteImages = onPasteImages
        return view
    }

    func updateUIView(_ view: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        view.onSubmit = onSubmit
        view.onPasteImages = onPasteImages
        view.canAttachImages = canAttachImages
        view.placeholderLabel.text = placeholder
        // Programmatic sets don't fire textViewDidChange — keep the
        // placeholder in sync here (typing goes through the delegate).
        if view.text != text {
            view.text = text
            view.updatePlaceholderVisibility()
        }
        view.updateScrollability()
        // Defer: becomeFirstResponder inside a view-update pass is ignored
        // during appearance transitions.
        if focused, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !focused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    /// Caps the field at roughly eight lines (the old lineLimit(1...8)),
    /// then the text view scrolls. Without this the representable would
    /// greedily eat whatever height the layout offers.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(fitting.height, uiView.maxContentHeight))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextField

        init(_ parent: ComposerTextField) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? ComposerUITextView)?.updatePlaceholderVisibility()
            (textView as? ComposerUITextView)?.updateScrollability()
        }

        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Software-keyboard Return. Shift+Return (hardware) arrives with
            // the flag set by pressesBegan; a pasted lone newline arrives
            // with isPasting set — neither may submit.
            if text == "\n", let view = textView as? ComposerUITextView,
               !view.isInsertingShiftNewline, !view.isPasting {
                parent.onSubmit()
                return false
            }
            return true
        }
    }
}

private final class ComposerUITextView: UITextView {
    var onSubmit: (() -> Void)?
    var onPasteImages: (([NSItemProvider]) -> Void)?
    var canAttachImages = false
    /// Set while Shift+Return is inserting a newline so the delegate
    /// doesn't read that newline as a submit.
    private(set) var isInsertingShiftNewline = false
    /// Set while a paste inserts text so a pasted lone "\n" isn't mistaken
    /// for the Return key.
    var isPasting = false

    let placeholderLabel = UILabel()

    /// Eight lines of Theme.Typography.body (15/22) plus the vertical inset.
    var maxContentHeight: CGFloat {
        let line = font?.lineHeight ?? 22
        return line * 8 + textContainerInset.top + textContainerInset.bottom
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        // Matches Theme.Typography.body (15 pt regular).
        font = .systemFont(ofSize: 15)
        textColor = .label
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        self.textContainer.lineFragmentPadding = 0
        isScrollEnabled = false
        returnKeyType = .send

        placeholderLabel.font = font
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textContainerInset.left),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top),
        ])
        updatePlaceholderVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    /// Scrolling stays off while the content fits, so the field grows with
    /// the text; past the cap it scrolls instead of stretching the card.
    func updateScrollability() {
        isScrollEnabled = false
        let fitting = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        isScrollEnabled = fitting.height > maxContentHeight + 1
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard press.key?.keyCode == .keyboardReturnOrEnter else { continue }
            if press.key?.modifierFlags.contains(.shift) == true {
                // Let UIKit insert the newline; the flag keeps the delegate
                // from treating it as a submit.
                isInsertingShiftNewline = true
                super.pressesBegan(presses, with: event)
                isInsertingShiftNewline = false
            } else {
                onSubmit?()
            }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: Paste — images become attachments, text stays in the field.

    override var pasteConfiguration: UIPasteConfiguration? {
        get {
            var types = [UTType.text.identifier, UTType.plainText.identifier, UTType.utf8PlainText.identifier]
            if canAttachImages { types.insert(UTType.image.identifier, at: 0) }
            return UIPasteConfiguration(acceptableTypeIdentifiers: types)
        }
        set {}
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), canAttachImages, UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        // Mixed text+image clipboard: attach the images AND insert the text
        // (rich-text editing is off, so super.paste drops images itself).
        if canAttachImages, UIPasteboard.general.hasImages {
            onPasteImages?(UIPasteboard.general.itemProviders)
        }
        if UIPasteboard.general.hasStrings {
            isPasting = true
            super.paste(sender)
            isPasting = false
        }
    }

    // The modern paste pipeline (keyboard shortcut bar) routes through
    // these; canPasteItemProviders comes from UIPasteConfigurationSupporting
    // (retroactive UITextView conformance) and can't take `override`.

    override func paste(itemProviders: [NSItemProvider]) {
        // Same payload as the general pasteboard — reuse the classic path.
        paste(nil)
    }

    func canPasteItemProviders(_ itemProviders: [NSItemProvider]) -> Bool {
        guard let acceptable = pasteConfiguration?.acceptableTypeIdentifiers else { return false }
        return itemProviders.contains { provider in
            acceptable.contains { provider.hasItemConformingToTypeIdentifier($0) }
        }
    }
}
#endif
