import SwiftUI

/// Token-style editor for an explicit list of artists. Each chip is one
/// artist; the inline text field adds new entries on Return or `,`/`;`.
/// The list is the source of truth — callers serialise it via
/// `ArtistResolver.joinExplicit(_:)` when writing to file tags.
struct ArtistsFieldView: View {
    @Binding var artists: [String]
    var label: String? = "Artist"
    var placeholder: String = "Add artist…"
    var compact: Bool = false

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label, !compact {
                HStack(spacing: 4) {
                    SheetLabel(text: label)
                    Spacer()
                    if artists.count > 1 {
                        Text("\(artists.count) artists")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Array(artists.enumerated()), id: \.offset) { index, name in
                    chip(name: name) {
                        artists.remove(at: index)
                    }
                }

                TextField(artists.isEmpty ? placeholder : "Add another", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: compact ? 80 : 110, minHeight: 22, alignment: .leading)
                    .onSubmit(commitDraft)
                    .onChange(of: draft) { _, new in
                        // Auto-commit when the user types a separator.
                        if let last = new.last, last == "," || last == ";" {
                            let trimmed = new.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                artists.append(String(trimmed))
                            }
                            draft = ""
                        }
                    }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, compact ? 3 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.textPrimary.opacity(0.05))
            )

        }
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        artists.append(trimmed)
        draft = ""
    }

    private func chip(name: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(
            Capsule().fill(Theme.textPrimary.opacity(0.09))
        )
    }
}

/// Minimal flow layout — wraps children to the next line when they exceed
/// the available width. Used by `ArtistsFieldView` so chips + the input
/// share a row and overflow gracefully.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalWidth = max(totalWidth, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        totalWidth = max(totalWidth, x - spacing)
        return CGSize(width: max(0, totalWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
