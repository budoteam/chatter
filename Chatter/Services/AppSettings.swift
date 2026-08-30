import Foundation

/// App-wide, non-secret preferences. UserDefaults on purpose: per-device,
/// no CloudKit schema/sync involvement (unlike @Model data).
enum AppSettings {
    private static let visionModelKey = "visionModel"
    private static let imageGenModelKey = "imageGenModel"
    private static let deviceIDKey = "deviceID"

    /// Globally configured vision fallback model (Settings → Vision).
    /// Empty string = disabled.
    static var visionModel: String {
        get { UserDefaults.standard.string(forKey: visionModelKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: visionModelKey) }
    }

    /// OpenRouter model used by the imagegen__generate tool (Settings →
    /// OpenRouter). Empty string = the tool stays off. Defaults to Google's
    /// image model; "None" in the picker stores an explicit empty string.
    static var imageGenModel: String {
        get { UserDefaults.standard.string(forKey: imageGenModelKey) ?? "google/gemini-2.5-flash-image" }
        set { UserDefaults.standard.set(newValue, forKey: imageGenModelKey) }
    }

    /// Stable per-device identifier, generated on first read. Used for
    /// handoff claims (which Mac took over a turn) — deliberately per-device
    /// UserDefaults, never synced.
    static var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: deviceIDKey)
        return fresh
    }
}
