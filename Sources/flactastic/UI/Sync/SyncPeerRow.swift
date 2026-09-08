import SwiftUI

/// One device in the Sync window's list.
struct SyncPeerRow: View {
    let name: String
    let kind: SyncDeviceKind
    let subtitle: String
    let isPaired: Bool
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
                .font(.system(size: 20))
                .frame(width: 28)
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(primaryTitle, action: onPrimary)
                    .disabled(!isEnabled)
            }

            if let onForget {
                Menu {
                    Button("Forget This Device", role: .destructive) { isConfirmingForget = true }
                } label: {
                    Image(systemName: "ellipsis")
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
        .padding(Theme.Spacing.md)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .opacity(isEnabled || isBusy ? 1 : 0.6)
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
