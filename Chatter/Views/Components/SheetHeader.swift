import SwiftUI

/// Plain header chrome for sheets on macOS.
///
/// `NavigationStack` toolbars inside a sheet make the hosting window's content
/// shift down by the toolbar height once the sheet closes (macOS SwiftUI bug),
/// so macOS sheets render this explicit header via `.safeAreaInset(edge: .top)`
/// instead of `.toolbar` items. iOS keeps the regular navigation bar.
struct SheetHeader<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(title)
                .font(.headline)
                .lineLimit(1)
            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }
}
