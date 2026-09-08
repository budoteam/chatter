import SwiftUI
import SwiftData
import Photos
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
            if !viewModel.pendingDocuments.isEmpty {
                documentStrip
            }
            if viewModel.imageLimitHit {
                Text("Some images were skipped — attachments are limited to 700 KB per message so the chat keeps syncing via iCloud.")
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }
            if viewModel.imageImportFailed {
                Text("Some images couldn't be loaded — they may still be syncing from iCloud. Please try again.")
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }
            if viewModel.documentLimitHit {
                Text("Some PDFs were skipped — document text is limited to 200'000 characters per message.")
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }
            if viewModel.documentImportFailed {
                Text("Some PDFs yielded no text — they may be corrupt, or scans that even OCR couldn't read.")
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
            // keyboard paste button, Cmd+V). Software-keyboard Return inserts
            // a newline; on hardware keyboards Return sends and Shift+Return
            // breaks (see ComposerUITextView.pressesBegan).
            ComposerTextField(
                text: $viewModel.inputText,
                focused: $focused,
                placeholder: placeholder,
                canAttachImages: viewModel.canAttachImages,
                onSubmit: performSend,
                onPasteImages: pasteImages,
                onPastePDFs: pastePDFs
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
                      focus.wrappedValue
                else { return event }
                if viewModel.canAttachImages,
                   let base64s = ImageAttachmentProcessor.base64JPEGsFromPasteboard() {
                    viewModel.addBase64Images(base64s)
                    return nil
                }
                // PDFs sind nicht an Vision-Support gekoppelt: Daten oder
                // Finder-Dateien aus dem Zwischenspeicher werden Anhänge.
                let payloads = Self.pasteboardPDFPayloads()
                if !payloads.isEmpty {
                    Task {
                        var drafts: [DocumentDraft] = []
                        var failed = 0
                        for payload in payloads {
                            if let draft = await Self.makeDraft(from: payload.data, fileName: payload.fileName) {
                                drafts.append(draft)
                            } else {
                                failed += 1
                            }
                        }
                        viewModel.addDocuments(drafts)
                        viewModel.documentImportFailed = failed > 0
                    }
                    return nil
                }
                return event
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
        // Text paste and non-PDF Finder file-copy paste keep falling through
        // to the text field (a file copy inserts its path). iOS handles paste
        // inside ComposerTextField — onPasteCommand is explicitly unavailable
        // there despite what Apple's docs claim.
        .onPasteCommand(of: [.image, .pdf]) { providers in
            let pdfProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }
            let imageProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
            Task {
                if !pdfProviders.isEmpty {
                    let (drafts, failed) = await Self.loadPDFDrafts(from: pdfProviders)
                    viewModel.addDocuments(drafts)
                    viewModel.documentImportFailed = failed > 0
                }
                if !imageProviders.isEmpty, viewModel.canAttachImages {
                    viewModel.addBase64Images(await ImageAttachmentProcessor.makeBase64JPEGs(from: imageProviders))
                }
            }
        }
        #endif
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: viewModel.canAttachImages ? [.image, .pdf] : [.pdf],
            allowsMultipleSelection: true
        ) { result in
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

    private var documentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.pendingDocuments) { draft in
                    DocumentChip(document: draft.attachment) {
                        viewModel.pendingDocuments.removeAll { $0.id == draft.id }
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
                .foregroundStyle(Color.secondary)
                .frame(width: 30, height: 30)
                .background(Theme.surfaceRaised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // PDFs work with every model (their text is extracted locally);
        // image files stay gated on the model's vision capability.
        .help(viewModel.canAttachImages
            ? "Attach images or PDFs"
            : "Attach PDFs")
        .accessibilityLabel(Text(viewModel.canAttachImages
            ? "Attach images or PDFs"
            : "Attach PDFs"))
    }

    private func loadPickedImages(_ items: [PhotosPickerItem]) async {
        var base64s: [String] = []
        var failed = 0
        for item in items {
            if let base64 = await Self.loadImageBase64(from: item) {
                base64s.append(base64)
            } else {
                failed += 1
            }
        }
        // Silent skips are the worst outcome here — log and surface them.
        if failed > 0 {
            AppLogger.ui.error("Photo import: \(failed, privacy: .public) of \(items.count, privacy: .public) image(s) could not be loaded")
        }
        viewModel.addBase64Images(base64s)
        viewModel.imageImportFailed = failed > 0
        photoItems = []
    }

    /// Original data first (best quality). On failure fall back to a
    /// Photos.framework rendition: it delivers a downsampled image instead of
    /// the full original (48 MP ProRAW originals are the classic raw-data
    /// failure) and handles iCloud downloads itself. The picker grants read
    /// access to its own selections — no library authorization needed.
    private static func loadImageBase64(from item: PhotosPickerItem) async -> String? {
        if let data = try? await item.loadTransferable(type: Data.self),
           let base64 = ImageAttachmentProcessor.makeBase64JPEG(from: data) {
            return base64
        }
        return await loadRenditionBase64(from: item)
    }

    #if os(macOS)
    private static func loadRenditionBase64(from item: PhotosPickerItem) async -> String? {
        guard let image = await requestRendition(from: item),
              let tiff = image.tiffRepresentation else { return nil }
        return ImageAttachmentProcessor.makeBase64JPEG(from: tiff)
    }

    private static func requestRendition(from item: PhotosPickerItem) async -> NSImage? {
        guard let asset = pickerAsset(for: item) else { return nil }
        return await withCheckedContinuation { continuation in
            // .highQualityFormat guarantees exactly one callback.
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1568, height: 1568),
                contentMode: .aspectFit,
                options: renditionOptions()
            ) { image, _ in continuation.resume(returning: image) }
        }
    }
    #else
    private static func loadRenditionBase64(from item: PhotosPickerItem) async -> String? {
        guard let image = await requestRendition(from: item),
              let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        return ImageAttachmentProcessor.makeBase64JPEG(from: data)
    }

    private static func requestRendition(from item: PhotosPickerItem) async -> UIImage? {
        guard let asset = pickerAsset(for: item) else { return nil }
        return await withCheckedContinuation { continuation in
            // .highQualityFormat guarantees exactly one callback.
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1568, height: 1568),
                contentMode: .aspectFit,
                options: renditionOptions()
            ) { image, _ in continuation.resume(returning: image) }
        }
    }
    #endif

    private static func pickerAsset(for item: PhotosPickerItem) -> PHAsset? {
        guard let assetID = item.itemIdentifier else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
    }

    private static func renditionOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        // Without this the rendition arrives at ORIGINAL size (targetSize is
        // only a decode hint) — the full ProRAW decode is what we're avoiding.
        options.resizeMode = .exact
        return options
    }

    private func loadFileURLs(_ urls: [URL]) async {
        var base64s: [String] = []
        var drafts: [DocumentDraft] = []
        var failedImages = 0
        var failedPDFs = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                if Self.isPDF(url) { failedPDFs += 1 } else { failedImages += 1 }
                continue
            }
            if Self.isPDF(url) {
                if let draft = await Self.makeDraft(from: data, fileName: url.lastPathComponent) {
                    drafts.append(draft)
                } else {
                    failedPDFs += 1
                }
            } else if let base64 = ImageAttachmentProcessor.makeBase64JPEG(from: data) {
                base64s.append(base64)
            } else {
                failedImages += 1
            }
        }
        if failedImages > 0 {
            AppLogger.ui.error("Image file import: \(failedImages, privacy: .public) file(s) could not be loaded")
        }
        if failedPDFs > 0 {
            AppLogger.ui.error("PDF import: \(failedPDFs, privacy: .public) file(s) yielded no text")
        }
        viewModel.addBase64Images(base64s)
        viewModel.addDocuments(drafts)
        viewModel.imageImportFailed = failedImages > 0
        viewModel.documentImportFailed = failedPDFs > 0
    }

    private static func isPDF(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) ?? false
    }

    /// Extraction + possible OCR are CPU-bound — off the main thread.
    static func makeDraft(from data: Data, fileName: String) async -> DocumentDraft? {
        await Task.detached(operation: {
            PDFAttachmentProcessor.makeDraft(from: data, fileName: fileName)
        }).value
    }

    /// PDFs from the system paste pipeline (data or file-URL payloads) become
    /// document drafts through the extraction/OCR pipeline. Shared sink for
    /// the iOS paste callback and the macOS paste command.
    static func loadPDFDrafts(from providers: [NSItemProvider]) async -> (drafts: [DocumentDraft], failed: Int) {
        var drafts: [DocumentDraft] = []
        var failed = 0
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            guard let payload = try? await provider.loadItem(forTypeIdentifier: UTType.pdf.identifier) else {
                failed += 1
                continue
            }
            let data: Data?
            let fileName: String
            switch payload {
            case let pdfData as Data:
                data = pdfData
                fileName = provider.suggestedName.map { $0 + ".pdf" } ?? "Pasteboard.pdf"
            case let url as URL:
                data = try? Data(contentsOf: url)
                fileName = url.lastPathComponent
            default:
                data = nil
                fileName = "Pasteboard.pdf"
            }
            if let data, let draft = await makeDraft(from: data, fileName: fileName) {
                drafts.append(draft)
            } else {
                failed += 1
            }
        }
        if failed > 0 {
            AppLogger.ui.error("PDF paste: \(failed, privacy: .public) item(s) yielded no text")
        }
        return (drafts, failed)
    }

    #if os(macOS)
    /// PDF payloads on the general pasteboard: raw PDF data first, then PDF
    /// file URLs (Finder copy). Empty when nothing PDF-like is on the board.
    private static func pasteboardPDFPayloads() -> [(data: Data, fileName: String)] {
        var payloads: [(Data, String)] = []
        for item in NSPasteboard.general.pasteboardItems ?? [] {
            if let data = item.data(forType: NSPasteboard.PasteboardType(UTType.pdf.identifier)) {
                payloads.append((data, "Pasteboard.pdf"))
            }
        }
        let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        for url in urls where UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) ?? false {
            if let data = try? Data(contentsOf: url) {
                payloads.append((data, url.lastPathComponent))
            }
        }
        return payloads
    }
    #endif

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

    /// PDFs from the system paste pipeline become document attachments —
    /// unlike images they work with every model (text is extracted locally).
    private func pastePDFs(_ providers: [NSItemProvider]) {
        Task {
            let (drafts, failed) = await Self.loadPDFDrafts(from: providers)
            viewModel.addDocuments(drafts)
            viewModel.documentImportFailed = failed > 0
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
/// paste keeps falling through to the field itself. Software-keyboard
/// Return inserts a newline; on hardware keyboards Return sends and
/// Shift+Return inserts the line break.
private struct ComposerTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let canAttachImages: Bool
    let onSubmit: () -> Void
    let onPasteImages: ([NSItemProvider]) -> Void
    let onPastePDFs: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.delegate = context.coordinator
        view.onSubmit = onSubmit
        view.onPasteImages = onPasteImages
        view.onPastePDFs = onPastePDFs
        return view
    }

    func updateUIView(_ view: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        view.onSubmit = onSubmit
        view.onPasteImages = onPasteImages
        view.onPastePDFs = onPastePDFs
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
    }
}

private final class ComposerUITextView: UITextView {
    var onSubmit: (() -> Void)?
    var onPasteImages: (([NSItemProvider]) -> Void)?
    var onPastePDFs: (([NSItemProvider]) -> Void)?
    var canAttachImages = false

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
        // Newline, not send: the software Return key inserts a line break
        // (hardware Return is handled in pressesBegan).
        returnKeyType = .default

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

    // Hardware keyboards only — software-keyboard input never arrives here.
    // Return sends; Shift+Return falls through to UIKit's newline insertion.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard press.key?.keyCode == .keyboardReturnOrEnter else { continue }
            if press.key?.modifierFlags.contains(.shift) == true {
                super.pressesBegan(presses, with: event)
            } else {
                onSubmit?()
            }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: Paste — images/PDFs become attachments, text stays in the field.

    override var pasteConfiguration: UIPasteConfiguration? {
        get {
            var types = [UTType.text.identifier, UTType.plainText.identifier, UTType.utf8PlainText.identifier,
                         UTType.pdf.identifier]
            if canAttachImages { types.insert(UTType.image.identifier, at: 0) }
            return UIPasteConfiguration(acceptableTypeIdentifiers: types)
        }
        set {}
    }

    /// PDF items currently on the general pasteboard.
    private var pasteboardPDFProviders: [NSItemProvider] {
        UIPasteboard.general.itemProviders.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            if canAttachImages, UIPasteboard.general.hasImages { return true }
            if !pasteboardPDFProviders.isEmpty { return true }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        // Mixed text+image clipboard: attach the images AND insert the text
        // (rich-text editing is off, so super.paste drops images itself).
        if canAttachImages, UIPasteboard.general.hasImages {
            onPasteImages?(UIPasteboard.general.itemProviders)
        }
        let pdfs = pasteboardPDFProviders
        if !pdfs.isEmpty {
            onPastePDFs?(pdfs)
        }
        if UIPasteboard.general.hasStrings {
            super.paste(sender)
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
