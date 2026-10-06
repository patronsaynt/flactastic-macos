import SwiftUI

// Shared chrome for the Collection and Playlists surfaces: the dense
// eyebrow+title page header, pill toggles, capsule sort/search controls and
// the hover affordances on artwork. Everything here reads from `Theme` so the
// light/dark ladders keep working.

// MARK: - Page header

/// Eyebrow label + oversized page title, with an optional trailing accessory
/// (e.g. the Collection refresh button).
struct FLPageHeader<Accessory: View>: View {
    let eyebrow: String
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.textSecondary)

            HStack(alignment: .bottom, spacing: Theme.Spacing.lg) {
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.9)
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.opacity)

                Spacer(minLength: 0)

                accessory()
            }
        }
    }
}

extension FLPageHeader where Accessory == EmptyView {
    init(eyebrow: String, title: String) {
        self.init(eyebrow: eyebrow, title: title) { EmptyView() }
    }
}

/// The smaller eyebrow used on detail screens and grouped-album section
/// headers.
struct FLEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Pill toggle

struct FLPillSegment<Value: Hashable>: Identifiable {
    let value: Value
    var title: String?
    var systemImage: String?
    var help: String?

    var id: Value { value }

    static func text(_ value: Value, _ title: String) -> FLPillSegment {
        FLPillSegment(value: value, title: title, systemImage: nil, help: nil)
    }

    static func icon(_ value: Value, _ systemImage: String, help: String) -> FLPillSegment {
        FLPillSegment(value: value, title: nil, systemImage: systemImage, help: help)
    }
}

/// Segmented control in the app's pill language — replaces `.pickerStyle(.segmented)`.
struct FLPillToggle<Value: Hashable>: View {
    @Binding var selection: Value
    let segments: [FLPillSegment<Value>]

    /// Lets the active pill slide between segments instead of popping.
    @Namespace private var activeSegment

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        selection = segment.value
                    }
                } label: {
                    segmentLabel(segment)
                }
                .buttonStyle(.plain)
                .help(segment.help ?? segment.title ?? "")
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.divider, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func segmentLabel(_ segment: FLPillSegment<Value>) -> some View {
        let isActive = segment.value == selection

        Group {
            if let title = segment.title {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
            } else if let systemImage = segment.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 26)
            }
        }
        .foregroundStyle(isActive ? Theme.textPrimary : Theme.textTertiary)
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surfaceElevated)
                    .matchedGeometryEffect(id: "activeSegment", in: activeSegment)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - Capsule controls

/// Capsule dropdown replacing `.pickerStyle(.menu)` on the redesigned tabs.
struct FLSortMenu<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(label(option), systemImage: "checkmark")
                    } else {
                        Text(label(option))
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Text(label(selection))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.leading, 13)
            .padding(.trailing, 11)
            .frame(height: 34)
            .background(FLCapsuleBackground())
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// 34pt circular icon button on the capsule surface — refresh, sort direction,
/// detail-view Edit.
struct FLCircleIconButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(FLCapsuleBackground())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Default glyph for `FLCircleIconButton`.
struct FLCircleIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .medium))
    }
}

extension FLCircleIconButton where Label == FLCircleIcon {
    init(systemImage: String, action: @escaping () -> Void) {
        self.init(action: action) { FLCircleIcon(systemImage: systemImage) }
    }
}

/// Shared background for the 34pt capsule controls (sort menu, search field,
/// circular buttons).
struct FLCapsuleBackground: View {
    var body: some View {
        Capsule()
            .fill(Theme.surface)
            .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
    }
}

// MARK: - Action pills

/// The 36pt Play / Shuffle / New Playlist pills from the redesign. Distinct
/// from `PillButtonStyle`, which stays as the modal-sheet button style.
struct FLActionPillStyle: ButtonStyle {
    var isPrimary: Bool = false
    /// 36pt for the Play/Shuffle actions; 34pt when sitting in a control row
    /// alongside the other capsule controls.
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isPrimary ? Theme.background : Theme.textSecondary)
            .padding(.horizontal, isPrimary ? 20 : 18)
            .frame(height: height)
            .background {
                if isPrimary {
                    Capsule().fill(configuration.isPressed ? Theme.textSecondary : Theme.accent)
                } else {
                    Capsule()
                        .fill(configuration.isPressed ? Theme.surfaceHover : Theme.surface)
                        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Chevron + label back control used by the playlist detail view. (The
/// album and artist pages use `HeroBackButton` over their artwork.)
struct FLBackLink: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Track list

/// The `# / TITLE / FORMAT / QUALITY / LENGTH` rule above a tracklist. Column
/// widths mirror `TrackRow`'s trailing badges exactly (see
/// `TrackRow.formatColumnWidth` etc.) so the labels stay aligned with the
/// values underneath regardless of badge content length.
struct FLTrackListHeader: View {
    /// Reserve trailing space matching a track list whose rows show a drag
    /// handle (`TrackRow(showDragHandle: true)`), so LENGTH lines up with the
    /// duration column rather than the handle beside it.
    var showDragHandle: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            Text("#")
                .font(.system(size: 11))
                .tracking(1)
                .frame(width: 26)

            Text("TITLE")
                .font(.system(size: 11))
                .tracking(1.5)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("FORMAT")
                .font(.system(size: 11))
                .tracking(1.5)
                .frame(width: TrackRow.formatColumnWidth, alignment: .center)

            Text("QUALITY")
                .font(.system(size: 11))
                .tracking(1.5)
                .frame(width: TrackRow.qualityColumnWidth, alignment: .center)

            Text("LENGTH")
                .font(.system(size: 11))
                .tracking(1.5)
                .frame(width: TrackRow.lengthColumnWidth, alignment: .trailing)

            if showDragHandle {
                Color.clear.frame(width: 18)
            }
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
        }
    }
}

// MARK: - Row / card hover affordances

private struct FLRowStyle: ViewModifier {
    /// Rows that carry their own selection/playing fill opt out of the hover
    /// fill so the two don't fight.
    var fill: Color? = nil

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fill ?? (isHovering ? Theme.surface : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { isHovering = $0 }
    }
}

/// Hover affordance for a library card's cover: a slight magnification, a
/// hairline highlight and a soft glow. Cards open their detail view on click —
/// hovering never offers playback.
private struct FLCoverHoverHighlight: ViewModifier {
    let isHovering: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.textPrimary.opacity(isHovering ? 0.30 : 0), lineWidth: 1)
            }
            .scaleEffect(isHovering ? 1.03 : 1)
            .shadow(color: Theme.textPrimary.opacity(isHovering ? 0.20 : 0), radius: 14)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.22), value: isHovering)
    }
}

/// The −3pt rise the whole card makes while hovered, paired with
/// `coverHoverHighlight` so both run off the card's single hover state.
private struct FLCardHoverLift: ViewModifier {
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .offset(y: isHovering ? -3 : 0)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.22), value: isHovering)
    }
}

extension View {
    /// The redesign's `.fl-row`: 9/10 padding, 10pt radius, surface fill on hover.
    func flRowStyle(fill: Color? = nil) -> some View {
        modifier(FLRowStyle(fill: fill))
    }

    /// −3pt rise on hover, matching the mockup's card easing.
    func cardHoverLift(isHovering: Bool) -> some View {
        modifier(FLCardHoverLift(isHovering: isHovering))
    }

    /// Magnify + highlight + glow a card's cover while the card is hovered.
    /// Apply *after* `.artworkShadow`, whose `.drawingGroup()` would otherwise
    /// swallow the glow; hence the explicit corner radius, since the highlight
    /// can't rely on the artwork's own `.clipShape`.
    func coverHoverHighlight(isHovering: Bool,
                             cornerRadius: CGFloat = Theme.Radius.md) -> some View {
        modifier(FLCoverHoverHighlight(isHovering: isHovering, cornerRadius: cornerRadius))
    }
}
