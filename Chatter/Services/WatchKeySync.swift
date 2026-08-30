#if os(iOS) || os(watchOS)
import Foundation
import WatchConnectivity

/// Syncs the API keys (Ollama, OpenRouter) from the iPhone to the watch.
///
/// The keychain items are already marked `kSecAttrSynchronizable`, but iCloud
/// Keychain does not reliably sync items to watchOS — so the watch asks its
/// paired iPhone over WatchConnectivity instead. The paired-device channel
/// is encrypted by the system, and `sendMessage` from the watch wakes the
/// iOS app in the background, so no "open the app on your phone" dance is
/// needed. There is intentionally no key-entry UI on the watch.
///
/// Protocol: the watch keeps sending the original `ollamaApiKey` request;
/// the phone answers with BOTH keys. Older phone builds simply omit the
/// OpenRouter field (watch keeps working, no image generation), and older
/// watch builds ignore the extra field — fully backward compatible.
@MainActor
final class WatchKeySync: NSObject {
    static let shared = WatchKeySync()

    /// Called on the watch after a key was received and stored, so the UI
    /// can flip from "waiting" to ready.
    var onKeyReceived: (() -> Void)?

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    #if os(watchOS)
    /// Asks the paired iPhone for the keys. No-op when both already exist
    /// locally or the session isn't ready (retried on reachability changes).
    func requestKeyIfNeeded() {
        guard !KeychainService.hasAPIKey || !KeychainService.hasOpenRouterAPIKey,
              let session else { return }
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["request": "ollamaApiKey"]) { reply in
            var received = false
            if let key = reply["ollamaApiKey"] as? String, !key.isEmpty {
                try? KeychainService.saveAPIKey(key)
                received = true
            }
            if let key = reply["openRouterApiKey"] as? String, !key.isEmpty {
                try? KeychainService.saveOpenRouterAPIKey(key)
                received = true
            }
            guard received else { return }
            Task { @MainActor in self.onKeyReceived?() }
        } errorHandler: { error in
            AppLogger.api.error("Watch key request failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}

extension WatchKeySync: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        #if os(watchOS)
        // Activation is the earliest point a request can succeed.
        Task { @MainActor in self.requestKeyIfNeeded() }
        #endif
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// The watch asks for the keys; reply with both (empty string when unset —
    /// older watch builds ignore the OpenRouter field).
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard message["request"] as? String == "ollamaApiKey" else { return }
        replyHandler([
            "ollamaApiKey": KeychainService.loadAPIKey() ?? "",
            "openRouterApiKey": KeychainService.loadOpenRouterAPIKey() ?? "",
        ])
    }
    #endif

    #if os(watchOS)
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in self.requestKeyIfNeeded() }
    }
    #endif
}
#endif
