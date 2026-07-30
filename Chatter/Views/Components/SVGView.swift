import SwiftUI
import WebKit

/// Renders an SVG string inline via a WKWebView. JavaScript is disabled —
/// model-generated SVG is untrusted content and may carry <script> tags or
/// external references, so the navigation delegate also blocks everything
/// except the initial about:blank load. The aspect ratio is parsed from the
/// SVG's viewBox/width/height in Swift (no JS round-trip), so the view sizes
/// itself synchronously inside the chat's LazyVStack.
struct SVGView: View {
    let svg: String

    var body: some View {
        SVGWebView(svg: svg)
            .frame(maxWidth: .infinity)
            .aspectRatio(Self.aspectRatio(of: svg) ?? 4 / 3, contentMode: .fit)
    }

    /// width/height from `viewBox` first, then explicit width/height attrs.
    /// Only the first chunk is scanned — SVGs can be large and the root tag
    /// always comes first.
    static func aspectRatio(of svg: String) -> CGFloat? {
        let head = String(svg.prefix(2_000))
        if let match = head.range(
            of: #"viewBox\s*=\s*["']([^"']+)["']"#, options: .regularExpression
        ) {
            let numbers = head[match]
                .replacingOccurrences(of: ",", with: " ")
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\"" || $0 == "'" })
                .compactMap { Double($0) }
            if numbers.count == 4, numbers[2] > 0, numbers[3] > 0 {
                return CGFloat(numbers[2] / numbers[3])
            }
        }
        func attribute(_ name: String) -> Double? {
            guard let match = head.range(
                of: name + #"\s*=\s*["']([0-9.]+)"#, options: .regularExpression
            ) else { return nil }
            let digits = head[match].drop { !$0.isNumber && $0 != "." }
            return Double(digits.prefix(while: { $0.isNumber || $0 == "." }))
        }
        if let width = attribute("width"), let height = attribute("height"),
           width > 0, height > 0 {
            return CGFloat(width / height)
        }
        return nil
    }
}

private struct SVGWebView {
    let svg: String

    static let htmlTemplate = """
        <!DOCTYPE html><html><head>\
        <meta name="viewport" content="width=device-width, initial-scale=1">\
        <style>html,body{margin:0;padding:0;background:transparent}\
        svg{display:block;width:100%;height:auto}</style>\
        </head><body>%@</body></html>
        """

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        #if canImport(UIKit)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        #elseif canImport(AppKit)
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        return webView
    }

    func load(_ webView: WKWebView, coordinator: Coordinator) {
        guard coordinator.loadedSVG != svg else { return }
        coordinator.loadedSVG = svg
        webView.loadHTMLString(
            String(format: Self.htmlTemplate, svg), baseURL: nil
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedSVG: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // Allow only the loadHTMLString navigation itself; SVG-external
            // resources (images, fonts, redirects) must not phone home.
            guard let url = navigationAction.request.url else { return .allow }
            return url.absoluteString == "about:blank" ? .allow : .cancel
        }
    }
}

#if canImport(UIKit)
extension SVGWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = makeWebView(coordinator: context.coordinator)
        load(webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        load(webView, coordinator: context.coordinator)
    }
}
#elseif canImport(AppKit)
extension SVGWebView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = makeWebView(coordinator: context.coordinator)
        load(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(webView, coordinator: context.coordinator)
    }
}
#endif
