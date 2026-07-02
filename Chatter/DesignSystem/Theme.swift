import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Central design tokens. Tuned to echo the Google Gemini app: airy neutral
/// canvas, soft rounded surfaces, and a signature blue→violet→magenta gradient.
enum Theme {
    // MARK: Brand gradient
    static let brandGradient = LinearGradient(
        colors: [
            Color(hex: "4F86FF"), // blue
            Color(hex: "8A5CF6"), // violet
            Color(hex: "E15CC0"), // magenta
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let accent = Color(hex: "6C5CE7")

    // MARK: Surfaces (semantic, adapt to light/dark)
    static let canvas = Color.dynamic(light: "FBFBFD", dark: "121316")
    static let surface = Color.dynamic(light: "FFFFFF", dark: "1C1D21")
    static let surfaceRaised = Color.dynamic(light: "F0F1F5", dark: "26272C")
    static let userBubble = Color.dynamic(light: "ECEEF6", dark: "2B2D34")
    static let separator = Color.dynamic(light: "E6E7EC", dark: "303138")

    // MARK: Text
    static var textPrimary: Color { .primary }
    static var textSecondary: Color { .secondary }

    // MARK: Metrics
    enum Radius {
        static let sm: CGFloat = 12
        static let md: CGFloat = 18
        static let lg: CGFloat = 24
        static let pill: CGFloat = 28
    }

    enum Spacing {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 36
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
        #if canImport(UIKit)
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
    }
}
