import SwiftUI

/// One device in the Sync list. Rendered as a row inside a `SettingsGroup`.
struct SyncPeerRow: View {
    let name: String
    let kind: SyncDeviceKind
    let subtitle: String
    let isPaired: Bool
    let isOnline: Bool
    let isBusy: Bool
    let isEnabled: Bool
    let primaryTitle: String
    let onPrimary: () -> Void
    /// `nil` for a device that isn't paired — there is nothing to forget.
    let onForget: (() -> Void)?

    @State private var isConfirmingForget = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .frame(width: 26)
                .foregroundStyle(Theme.textTertiary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if isPaired {
                        Circle()
                            .fill(isOnline ? Theme.qualityCD : Theme.textTertiary.opacity(0.5))
                            .frame(width: 6, height: 6)
                    }
                }
                Text(subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            if isBusy {
                ProgressView().controlSize(.small)
            } else if isOnline {
                Button(primaryTitle, action: onPrimary)
                    .buttonStyle(PillButtonStyle(isPrimary: isPaired))
                    .disabled(!isEnabled)
                    .opacity(isEnabled ? 1 : 0.4)
            }

            if let onForget {
                Menu {
                    Button("Forget This Device", role: .destructive) { isConfirmingForget = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .confirmationDialog(
                    "Forget \(name)?",
                    isPresented: $isConfirmingForget,
                    titleVisibility: .visible
                ) {
                    Button("Forget", role: .destructive) { onForget() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    // Say plainly that this is a real revocation, not just a
                    // tidy-up of the list.
                    Text("This Mac will no longer accept syncs from \(name), and you'll need "
                       + "to pair again to sync with it. Your music isn't affected.")
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private var icon: String {
        switch kind {
        case .mac:    return "desktopcomputer"
        case .iPhone: return "iphone"
        case .iPad:   return "ipad"
        case .other:  return "display"
        }
    }
}
