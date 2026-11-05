import SwiftUI

/// A small pill at the bottom of the window while genres (or an import's
/// lyrics) are being fetched: "Pulling genres for Census Designated…".
/// Clears itself when the work ends.
struct GenreStatusPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let status = GenreScanner.shared.status
        ZStack {
            if let status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.08)))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.easeOut(duration: 0.25), value: status)
        .allowsHitTesting(false)
    }
}
