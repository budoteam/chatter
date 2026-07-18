import SwiftUI

/// Shared chrome for the overview grids (Agents, Knowledge): fixed padding,
/// minimum height, rounded surface with a separator stroke. Tap gesture and
/// context menu stay with the caller.
private struct OverviewCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

extension View {
    func overviewCardStyle() -> some View {
        modifier(OverviewCardStyle())
    }
}

/// Dashed accent card closing an overview grid. Either a plain button
/// (`action:`) or a menu (`menuContent:`) when there is more than one way
/// to add an entity.
struct AddEntityCard<MenuContent: View>: View {
    let title: String
    private var action: (() -> Void)?
    @ViewBuilder private var menuContent: MenuContent

    init(title: String, action: @escaping () -> Void) where MenuContent == EmptyView {
        self.title = title
        self.action = action
        self.menuContent = EmptyView()
    }

    init(title: String, @ViewBuilder menuContent: () -> MenuContent) {
        self.title = title
        self.action = nil
        self.menuContent = menuContent()
    }

    var body: some View {
        if let action {
            Button(action: action) { cardLabel }
                .buttonStyle(.plain)
        } else {
            Menu { menuContent } label: { cardLabel }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
        }
    }

    private var cardLabel: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}
