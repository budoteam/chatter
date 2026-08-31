import Foundation
@testable import Chatter

/// Hosted tests share the app's real UserDefaults domain — without isolation
/// every suite writing `AppSettings` rewrites the user's actual preferences
/// (a tearDown used to reset the chosen image model to "None" after each run).
enum TestDefaults {
    private static let suiteName = "ChatterTests.AppSettings"

    /// Points `AppSettings` at an empty scratch suite. Call first in `setUp`,
    /// before setting any `AppSettings` values.
    static func install() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        guard let scratch = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName: \(suiteName)) unavailable")
        }
        AppSettings.defaults = scratch
    }

    /// Restores the real defaults and drops the scratch suite. Call in `tearDown`.
    static func restore() {
        AppSettings.defaults = .standard
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
}
