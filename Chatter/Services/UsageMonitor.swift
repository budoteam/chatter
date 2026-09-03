import Foundation

/// Holds the latest Ollama Cloud subscription usage (`/api/usage`) for the
/// sidebar status. Best-effort: failures land in `errorMessage` instead of
/// surfacing alerts.
@MainActor
@Observable
final class UsageMonitor {
    private(set) var response: OllamaUsageResponse?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastUpdated: Date?

    /// Refreshes the usage. No-op while a load is already in flight.
    func refresh(using service: OllamaServiceProtocol) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            response = try await service.usage()
            errorMessage = nil
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.api.error("Usage fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
