import SwiftUI

/// Standard chrome for modal sheets in FLACtastic.
///
/// Owns the header (the sheet's name in small spaced capitals and a round
/// close button), the surface background, the fixed frame, the hairline over
/// the footer, and the layout that keeps the footer at the bottom however
/// tall the body is, preventing the "content centered in a too-tall frame"
/// bug that recurs when each sheet builds its own `VStack` skeleton.
///
/// The close button doesn't take Esc: sheets give that to their own Cancel,
/// which may need to clean up before dismissing.
///
/// Use this for `.sheet`-presented modal editors. **Do not** use it for
/// popovers, menus, alerts, the queue panel, or `MenuBarExtra` content —
/// those have legitimately different layout needs.
///
/// ```swift
/// FLSheet(title: "Edit Playlist", width: 660, height: 420) {
///     formBody
/// } footer: {
///     HStack {
///         Spacer()
///         Button("Cancel") { … }.buttonStyle(SheetPillStyle())
///         Button("Save") { … }.buttonStyle(SheetPillStyle(isPrimary: true))
///     }
/// }
/// ```
struct FLSheet<Content: View, Footer: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    var width: CGFloat = 520
    var height: CGFloat = 500
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Greedy in height with top alignment: natural-height content sticks
            // to the top (header anchored, footer at bottom); greedy content
            // (e.g. a loading spinner using `maxHeight: .infinity`) fills the
            // whole region. Avoids fighting between content and a trailing
            // Spacer when both are vertically flexible.
            //
            // A form taller than the sheet scrolls instead of pushing the
            // footer out of the frame. Content that fits (or that fills the
            // space, or scrolls itself) is shown as is.
            ViewThatFits(in: .vertical) {
                content()
                    .frame(maxHeight: .infinity, alignment: .top)
                ScrollView {
                    content()
                }
                .scrollIndicators(.automatic)
            }
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
            footer()
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, height: height)
        .background(Theme.surface)
    }

    /// The sheet's name in small spaced capitals, and a round close button.
    private var header: some View {
        HStack {
            SheetLabel(text: title)
            Spacer()
            // Esc stays with each sheet's own Cancel, as before.
            SheetCloseButton(label: "Close without saving", handlesEscape: false) { dismiss() }
        }
        .padding(.leading, 28)
        .padding(.trailing, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}
