import Foundation

/// App-wide, non-secret preferences. UserDefaults on purpose: per-device,
/// no CloudKit schema/sync involvement (unlike @Model data).
enum AppSettings {
    private static let visionModelKey = "visionModel"

    /// Globally configured vision fallback model (Settings → Vision).
    /// Empty string = disabled.
    static var visionModel: String {
        get { UserDefaults.standard.string(forKey: visionModelKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: visionModelKey) }
    }
}
