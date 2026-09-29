import SwiftUI

/// A titled group of rows rendered on a raised surface card. Shared by the
/// Settings panes and the Sync UI so both read as the same system.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .kerning(0.6)
                    .padding(.horizontal, 2)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Hair-line divider between rows inside a SettingsGroup.
struct GroupDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 0.5)
            .padding(.leading, Theme.Spacing.lg)
    }
}
