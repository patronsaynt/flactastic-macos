import SwiftUI

/// Asks for the eight digits shown on the other device.
///
/// The code is typed here, not scanned or tapped, because that is what makes
/// the pairing meaningful: the user reads it off a screen they are physically
/// looking at, which is the one thing an attacker on the same network cannot
/// do. The sheet says so, briefly, rather than presenting the code as an
/// arbitrary formality.
struct PairingCodeEntrySheet: View {
    let peer: DiscoveredPeer
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var code = ""
    @FocusState private var isFocused: Bool

    private var normalized: String { PairingCrypto.normalizeTypedCode(code) }
    private var isValid: Bool { PairingCrypto.isWellFormedCode(normalized) }

    var body: some View {
        FLSheet(title: "Pair with \(peer.displayName)", width: 440, height: 340) {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("On \(peer.displayName), choose File → Sync… (or Settings ▸ Devices) and select "
                   + "Show Code, then type the eight digits here.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("00000000", text: $code)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                    .focused($isFocused)
                    .onSubmit { if isValid { onSubmit(normalized) } }

                if !peer.isPairingOpen {
                    Text("\(peer.displayName) isn't showing a code right now.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(Theme.Spacing.xl)
        } footer: {
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Pair") { onSubmit(normalized) }
                    .buttonStyle(PillButtonStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
                    .opacity(isValid ? 1 : 0.4)
            }
        }
        .onAppear { isFocused = true }
    }
}
