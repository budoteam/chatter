import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Central design tokens. Iris accent on a quiet neutral canvas, a five-level
/// surface hierarchy, explicit text steps, and a unified type/space/radius/motion
/// scale. Content before chrome: compact spacing, technical radii.
enum Theme {
    // MARK: Brand gradient
    static let brandGradient = LinearGradient(
        colors: [
            Color(hex: "6947D7"), // iris
            Color(hex: "8E6BE6"), // lavender
            Color(hex: "B886E6"), // pink
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Accent
    static let accent = Color.dynamic(light: "6947D7", dark: "9A8BF0")

    // MARK: Accent fill (solid)
    /// Solid Iris for primary action surfaces (replaces brandGradient on buttons).
    static let accentFill = Color.dynamic(light: "6947D7", dark: "9A8BF0")

    // MARK: Surfaces (semantic, adapt to light/dark)
    static let canvas = Color.dynamic(light: "F6F6F8", dark: "0F1013")
    static let surface = Color.dynamic(light: "FFFFFF", dark: "17191E")
    static let surfaceRaised = Color.dynamic(light: "EEEFF3", dark: "20232A")
    static let overlay = Color.dynamic(light: "FFFFFF", dark: "23262E")
    // Opacity (24% light / 40% dark) is applied at the callsite.
    static let scrim = Color.dynamic(light: "000000", dark: "000000")

    // MARK: Brand surface (user bubble)
    static let userBubble = Color.dynamic(light: "ECE9FA", dark: "292743")

    // MARK: Separator
    static let separator = Color.dynamic(light: "E3E4E9", dark: "2C2F37")

    // MARK: Text
    static let textPrimary = Color.dynamic(light: "17181D", dark: "F1F2F5")
    static let textSecondary = Color.dynamic(light: "535864", dark: "A3A8B4")
    static let textTertiary = Color.dynamic(light: "6C7387", dark: "8A91A0")

    // MARK: Semantic
    enum Semantic {
        static let success = Color.dynamic(light: "1E9E66", dark: "46C489")
        static let warning = Color.dynamic(light: "C26E00", dark: "F0B23E")
        static let danger = Color.dynamic(light: "D23F3F", dark: "EE7070")
        static let streamPulse = Color.dynamic(light: "6947D7", dark: "9A8BF0")
    }

    // MARK: Metrics
    enum Radius {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
        static let pill: CGFloat = 9999
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    // MARK: Motion
    enum Motion {
        enum Duration {
            static let instant: Double = 0
            static let fast: Double = 0.12
            static let normal: Double = 0.20
            static let slow: Double = 0.32
        }

        enum Easing {
            static let standard = Animation.timingCurve(0.2, 0, 0, 1, duration: Duration.normal)
            static let decel = Animation.timingCurve(0, 0, 0.2, 1, duration: Duration.normal)
            static let accel = Animation.timingCurve(0.4, 0, 1, 1, duration: Duration.normal)
        }
    }

    // MARK: Typography
    enum Typography {
        /// Raw scale values; `font(_:)` materialises these into `Font` styles.
        /// A struct (not a tuple) so call sites can use implicit member syntax
        /// (`Theme.Typography.font(.body)`) — tuples can't carry static members.
        struct Style {
            let size: CGFloat
            let weight: Font.Weight
            let line: CGFloat
            let tracking: CGFloat

            static let display = Style(size: 30, weight: .semibold, line: 36, tracking: -0.4)
            static let title1 = Style(size: 22, weight: .semibold, line: 28, tracking: -0.3)
            static let title2 = Style(size: 17, weight: .semibold, line: 22, tracking: -0.2)
            static let title3 = Style(size: 15, weight: .semibold, line: 20, tracking: -0.1)
            static let body = Style(size: 15, weight: .regular, line: 22, tracking: 0)
            static let bodyEmphasis = Style(size: 15, weight: .medium, line: 22, tracking: 0)
            static let callout = Style(size: 14, weight: .regular, line: 20, tracking: 0)
            static let footnote = Style(size: 13, weight: .regular, line: 18, tracking: 0.1)
            static let caption = Style(size: 12, weight: .regular, line: 16, tracking: 0.2)
            static let mono = Style(size: 13, weight: .regular, line: 20, tracking: 0)
            static let monoSmall = Style(size: 12, weight: .regular, line: 18, tracking: 0)
        }

        static func font(_ style: Style) -> Font {
            .system(size: style.size, weight: style.weight)
        }
        static func lineHeight(_ style: Style) -> CGFloat { style.line }
        static func tracking(_ style: Style) -> CGFloat { style.tracking }
    }

    // MARK: Elevation
    enum Elevation {
        /// Shadow parameters; opacity differs per appearance.
        typealias ShadowStyle = (y: CGFloat, blur: CGFloat, opacityLight: Double, opacityDark: Double)

        /// No shadow.
        static let level0: ShadowStyle = (0, 0, 0, 0)
        /// Cards, popovers.
        static let level1: ShadowStyle = (1, 2, 0.06, 0.16)
        /// Sheets, inspector.
        static let level2: ShadowStyle = (8, 24, 0.10, 0.28)
    }
}

// MARK: - Elevation view modifier

private extension Theme.Elevation {
    struct Modifier: ViewModifier {
        let level: ShadowStyle
        @Environment(\.colorScheme) private var colorScheme

        func body(content: Content) -> some View {
            if level.y == 0 && level.blur == 0 {
                content
            } else {
                content.shadow(
                    color: Color.black.opacity(colorScheme == .dark ? level.opacityDark : level.opacityLight),
                    radius: level.blur / 2,
                    y: level.y
                )
            }
        }
    }
}

extension View {
    /// Applies the shadow style for a given elevation level.
    /// - Parameter level: shadow parameters (y, blur, opacity per appearance).
    func elevated(_ level: Theme.Elevation.ShadowStyle) -> some View {
        modifier(Theme.Elevation.Modifier(level: level))
    }
}

// MARK: - Hex color helper

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// A color that resolves to `light`/`dark` hex values per the active appearance.
    static func dynamic(light: String, dark: String) -> Color {
        #if os(watchOS)
        // watchOS has no light appearance — the interface is always dark.
        return Color(hex: dark)
        #elseif canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
        #endif
    }

    /// Hex string (RRGGBB) for persistence.
    var hexString: String {
        #if os(watchOS)
        // Neither UIColor nor NSColor exists on watchOS; `resolve(in:)`
        // (watchOS 10+) is the cross-platform way to read components.
        let resolved = resolve(in: EnvironmentValues())
        return String(
            format: "%02X%02X%02X",
            Int(resolved.red * 255), Int(resolved.green * 255), Int(resolved.blue * 255)
        )
        #else
        #if canImport(UIKit)
        typealias NativeColor = UIColor
        #else
        typealias NativeColor = NSColor
        #endif
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        NativeColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        NativeColor(self).usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        #endif
    }
}
