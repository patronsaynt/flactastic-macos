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
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Pair with \(peer.displayName)")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("On \(peer.displayName), choose File → Sync… and select Show Pairing Code, "
                   + "then type the eight digits here.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("00000000", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 26, weight: .medium, design: .monospaced))
                .focused($isFocused)
                .onSubmit { if isValid { onSubmit(normalized) } }

            if !peer.isPairingOpen {
                Text("\(peer.displayName) isn't showing a code right now.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Pair") { onSubmit(normalized) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 420)
        .background(Theme.background)
        .onAppear { isFocused = true }
    }
}
