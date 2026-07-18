import SwiftUI

/// Cross-platform sheet chrome: title plus leading / secondary / trailing
/// actions, so editor views only carry content and their buttons.
///
/// iOS wraps the content in a `NavigationStack` with an inline title and
/// toolbar items (leading → `.cancellationAction`, secondary →
/// `.secondaryAction`, trailing → `.confirmationAction`). macOS renders a
/// `SheetHeader` via `.safeAreaInset(edge: .top)` instead: a
/// `NavigationStack` toolbar inside a sheet makes the hosting window's
/// content shift down by the toolbar height once the sheet closes (macOS
/// SwiftUI bug), so macOS sheets get no toolbar chrome — see `SheetHeader`.
/// macOS sheets also size themselves, hence the minimum size (iOS-only
/// callers pass it too; it is ignored there).
///
/// Sheets that drill into sub-pages pass a `path` binding: the navigation
/// stack then exists on both platforms (e.g. KnowledgeBundleView pushes
/// concept editors on macOS as well). The macOS header stays outside the
/// stack, so it remains visible while drilled in.
struct EditorSheet<Content: View, Leading: View, Secondary: View, Trailing: View, PathElement: Hashable>: View {
    let title: String
    /// Minimum sheet size — macOS only, iOS sheets size themselves.
    let minWidth: CGFloat
    let minHeight: CGFloat
    /// Drill-down path; nil for plain sheets without a macOS navigation stack.
    var path: Binding<[PathElement]>?
    @ViewBuilder var leading: Leading
    @ViewBuilder var secondary: Secondary
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(
        title: String,
        minWidth: CGFloat,
        minHeight: CGFloat,
        path: Binding<[PathElement]>?,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder secondary: () -> Secondary,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.path = path
        self.leading = leading()
        self.secondary = secondary()
        self.trailing = trailing()
        self.content = content()
    }

    private var hasLeading: Bool { Leading.self != EmptyView.self }
    private var hasSecondary: Bool { Secondary.self != EmptyView.self }

    var body: some View {
        #if os(macOS)
        rootedContent
            // ContentUnavailableView only takes its ideal size on macOS;
            // without this the header+content unit centers in the sheet,
            // leaving a gap above the header.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: title) {
                    headerLeading
                } trailing: {
                    trailing
                }
            }
            .frame(minWidth: minWidth, minHeight: minHeight)
        #else
        rootedContent
        #endif
    }

    /// Navigation root: a stack when the sheet can drill into sub-pages
    /// (`path` set, both platforms) or to carry the iOS chrome; bare content
    /// otherwise — plain macOS sheets deliberately have no NavigationStack
    /// (see the type docs above).
    @ViewBuilder
    private var rootedContent: some View {
        if let path {
            NavigationStack(path: path) { chromedContent }
        } else {
            #if os(iOS)
            NavigationStack { chromedContent }
            #else
            chromedContent
            #endif
        }
    }

    /// iOS chrome lives inside the navigation stack; macOS chrome is the
    /// `SheetHeader` applied outside in `body`.
    private var chromedContent: some View {
        content
        #if os(iOS)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if hasLeading {
                    ToolbarItem(placement: .cancellationAction) { leading }
                }
                if hasSecondary {
                    ToolbarItem(placement: .secondaryAction) { secondary }
                }
                ToolbarItem(placement: .confirmationAction) { trailing }
            }
        #endif
    }

    /// Secondary actions join the leading side of the macOS header (iOS
    /// places them as `.secondaryAction` toolbar items instead).
    @ViewBuilder
    private var headerLeading: some View {
        if hasSecondary {
            HStack(spacing: 12) {
                leading
                secondary
            }
        } else {
            leading
        }
    }
}

extension EditorSheet where PathElement == Never {
    /// Sheets without drill-down navigation.
    init(
        title: String,
        minWidth: CGFloat,
        minHeight: CGFloat,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder secondary: () -> Secondary,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, minWidth: minWidth, minHeight: minHeight, path: nil,
            leading: leading, secondary: secondary, trailing: trailing, content: content
        )
    }
}

extension EditorSheet where Secondary == EmptyView {
    /// Sheets without a secondary action.
    init(
        title: String,
        minWidth: CGFloat,
        minHeight: CGFloat,
        path: Binding<[PathElement]>?,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, minWidth: minWidth, minHeight: minHeight, path: path,
            leading: leading, secondary: { EmptyView() }, trailing: trailing, content: content
        )
    }
}

extension EditorSheet where Secondary == EmptyView, PathElement == Never {
    /// Plain sheets: no drill-down navigation, no secondary action.
    init(
        title: String,
        minWidth: CGFloat,
        minHeight: CGFloat,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, minWidth: minWidth, minHeight: minHeight, path: nil,
            leading: leading, secondary: { EmptyView() }, trailing: trailing, content: content
        )
    }
}

extension EditorSheet where Leading == EmptyView, Secondary == EmptyView {
    /// Sheets with only a trailing action (e.g. a plain "Done").
    init(
        title: String,
        minWidth: CGFloat,
        minHeight: CGFloat,
        path: Binding<[PathElement]>?,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, minWidth: minWidth, minHeight: minHeight, path: path,
            leading: { EmptyView() }, secondary: { EmptyView() },
            trailing: trailing, content: content
        )
    }
}

extension EditorSheet where Leading == EmptyView, Secondary == EmptyView, PathElement == Never {
    /// Plain sheets with only a trailing action.
    init(
        title: String,
        minWidth: CGFloat,
        minHeight: CGFloat,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, minWidth: minWidth, minHeight: minHeight, path: nil,
            leading: { EmptyView() }, secondary: { EmptyView() },
            trailing: trailing, content: content
        )
    }
}
