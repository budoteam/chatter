import Foundation

/// App-wide, non-secret preferences. UserDefaults on purpose: per-device,
/// no CloudKit schema/sync involvement (unlike @Model data).
enum AppSettings {
    private static let visionModelKey = "visionModel"
    private static let deviceIDKey = "deviceID"

    /// Globally configured vision fallback model (Settings → Vision).
    /// Empty string = disabled.
    static var visionModel: String {
        get { UserDefaults.standard.string(forKey: visionModelKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: visionModelKey) }
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
