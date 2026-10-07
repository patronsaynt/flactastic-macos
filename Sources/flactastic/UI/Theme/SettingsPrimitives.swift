import SwiftUI

/// A titled group of rows. Shared by the Settings panes and the Sync UI so
/// both read as the same system.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content

    /// No box: a spaced-capitals label, then the rows straight on the sheet,
    /// split by hairlines. Rows keep their own horizontal padding, so the
    /// stack is pulled out by the same amount to line their text up with
    /// the label.
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(Theme.textTertiary)
            }
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, -Theme.Spacing.lg)
        }
    }
}

/// Hair-line divider between rows inside a SettingsGroup.
struct GroupDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 0.5)
            .padding(.horizontal, Theme.Spacing.lg)
    }
}

/// A plain capsule switch: filled with the accent (white in dark mode, black
/// in light) when on, a quiet grey when off. Replaces the system switch in
/// the sheets so it matches the rest of the app.
struct FLSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            configuration.label
            // A Button, so a disabled toggle can't be flipped.
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(configuration.isOn ? Theme.textPrimary : Theme.textPrimary.opacity(0.16))
                    .frame(width: 40, height: 24)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? Theme.background : Theme.textPrimary.opacity(0.55))
                            .frame(width: 18, height: 18)
                            .padding(3)
                    }
                    .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2), value: configuration.isOn)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
    }
}

// MARK: - Sheet chrome

/// The sheets' close control: a small round ✕. With `handlesEscape`, Esc
/// triggers it too; sheets whose own Cancel does cleanup on Esc pass false
/// so the two don't compete for the key.
struct SheetCloseButton: View {
    var label = "Close"
    var handlesEscape = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.textPrimary.opacity(isHovering ? 0.12 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(handlesEscape ? .cancelAction : nil)
        .onHover { isHovering = $0 }
        .help(handlesEscape ? "\(label) (Esc)" : label)
        .accessibilityLabel(label)
    }
}

/// The sheets' action pills: Save solid in the accent, Cancel a quiet fill.
struct SheetPillStyle: ButtonStyle {
    var isPrimary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isPrimary ? Theme.background : Theme.textPrimary)
            .padding(.horizontal, 22)
            .frame(height: 40)
            .background(Capsule().fill(isPrimary ? Theme.textPrimary : Theme.textPrimary.opacity(0.08)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Spaced capitals over a field or group in the edit sheets.
struct SheetLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .kerning(1.4)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// A field that reads as plain text until hovered or focused, then shows a
/// faint fill: the edit sheets' fields are the values themselves.
struct QuietFieldStyle: TextFieldStyle {
    var font: Font = .system(size: 15, weight: .semibold)
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Theme.textPrimary)
            .focused($isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.textPrimary.opacity(isFocused ? 0.07 : (isHovering ? 0.045 : 0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.textPrimary.opacity(isFocused ? 0.12 : 0), lineWidth: 1)
            )
            .padding(.horizontal, -10)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

/// An on/off pill for the edit sheets (Compilation, Mix Compilation): an
/// outline when off, solid in the accent when on.
struct SheetTogglePill: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isOn ? Theme.background : Theme.textSecondary)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(Capsule().fill(isOn ? Theme.textPrimary : .clear))
                .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(isOn ? 0 : 0.14), lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// A small grey text action (Remove cover).
struct QuietTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietTextButton(configuration: configuration)
    }

    private struct QuietTextButton: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textTertiary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Theme.textPrimary.opacity(isHovering ? 0.06 : 0)))
                .onHover { isHovering = $0 }
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

/// Over a cover in the edit sheets: "Change cover" on hover, or a
/// permanent "Add cover" when there's none.
struct CoverEditOverlay: View {
    enum OverlayShape { case rounded, circle }

    let isEmpty: Bool
    var emptyLabel = "Add cover"
    var changeLabel = "Change cover"
    var shape: OverlayShape = .rounded
    @State private var isHovering = false

    var body: some View {
        ZStack {
            if isEmpty || isHovering {
                Group {
                    switch shape {
                    case .rounded:
                        RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                            .fill(.black.opacity(isEmpty ? 0.15 : 0.45))
                    case .circle:
                        Circle().fill(.black.opacity(isEmpty ? 0.15 : 0.45))
                    }
                }
                Text(isEmpty ? emptyLabel : changeLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.18), value: isHovering)
    }
}
