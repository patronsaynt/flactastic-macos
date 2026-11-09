import SwiftUI
import AppKit

// MARK: - Title

/// A track's big title, word by word: words past `revealed` wait offset by
/// `from`, blurred and clear, and spring into place as the count rises.
struct OnboardingTitle: View {
    let text: String
    let revealed: Int
    let from: CGSize
    let fontSize: CGFloat

    var body: some View {
        let words = text.split(separator: " ").map(String.init)
        WordFlow(spacing: fontSize * 0.24, lineSpacing: -fontSize * 0.16) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                let shown = i < revealed
                Text(word)
                    .font(.system(size: fontSize, weight: .heavy))
                    .tracking(-fontSize * 0.04)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize()
                    .opacity(shown ? 1 : 0)
                    .blur(radius: shown ? 0 : 10)
                    .offset(shown ? .zero : from)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Lays words out left to right, wrapping onto new lines.
struct WordFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height(of: rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }

    private func height(of rows: [Row]) -> CGFloat {
        rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
    }
}

// MARK: - Skew

/// Shears content sideways, for the skip's tear-off.
struct SkewEffect: GeometryEffect {
    var skew: Double

    nonisolated var animatableData: Double {
        get { skew }
        set { skew = newValue }
    }

    nonisolated func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(skew * .pi / 180)), d: 1, tx: -size.height / 2 * CGFloat(tan(skew * .pi / 180)), ty: 0))
    }
}

// MARK: - Controls

/// A large radio card: the fork's two sides.
struct OnboardingChoice: View {
    let icon: String
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(height: 30)
                    .padding(.bottom, 24)
                Text(title)
                    .font(.system(size: 19, weight: .heavy))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Theme.textPrimary.opacity(isSelected || isHovering ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isSelected ? Theme.textPrimary : Theme.textPrimary.opacity(0.1), lineWidth: isSelected ? 2 : 1))
            .overlay(alignment: .topTrailing) { OnboardingRadio(isOn: isSelected).padding(16) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct OnboardingRadio: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .strokeBorder(isOn ? Theme.textPrimary : Theme.textTertiary, lineWidth: isOn ? 5.5 : 1.5)
            .frame(width: 18, height: 18)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.35), value: isOn)
    }
}

/// A row to act on: an icon tile, a title and a line under it, an action word.
struct OnboardingOption: View {
    let icon: String
    let title: String
    let detail: String
    var action: String? = nil
    var isProminent = false
    var isTargeted = false
    let perform: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isProminent ? Theme.background : Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(isProminent ? Theme.textPrimary : Theme.textPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 10)
                if let action {
                    Text(action)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .padding(.vertical, 14)
            .background(Theme.textPrimary.opacity(isHovering || isTargeted ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isTargeted ? Theme.textPrimary : Theme.textPrimary.opacity(0.1), lineWidth: isTargeted ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

/// A row stating something that's done: a filled tick, a title, a detail,
/// an optional accessory.
struct OnboardingDoneRow<Accessory: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.background)
                .frame(width: 44, height: 44)
                .background(Theme.textPrimary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 10)
            accessory()
        }
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Four bars bouncing: the playing track's number.
struct OnboardingEqualizer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.textPrimary)
                    .frame(width: 4, height: 20)
                    .scaleEffect(y: up ? [1, 0.45, 0.85, 0.3][i] : [0.3, 1, 0.4, 0.9][i], anchor: .bottom)
                    .animation(reduceMotion ? nil : .easeInOut(duration: [0.55, 0.4, 0.65, 0.48][i]).repeatForever(autoreverses: true), value: up)
            }
        }
        .frame(height: 20)
        .onAppear { up = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Theme flood

/// The look's flood: for a moment the stage is drawn twice, the old look
/// over the new, with a circle cut out of the old one that grows from where
/// you clicked, so the new theme pours out of the click. Drawn live rather
/// than from a snapshot, which would flatten the case's 3D faces.
@MainActor @Observable
final class ThemeFlood {
    private(set) var isPouring = false
    private(set) var oldScheme: ColorScheme = .dark
    private(set) var origin: CGPoint = .zero
    var radius: CGFloat = 0
    private var generation = 0

    /// Holds the old look (`from`) over the window, runs `change` (the theme
    /// switch) under it, then opens the circle from the pointer.
    /// `point` is where the choice was made, in the window; without one,
    /// the pointer.
    func pour(from scheme: ColorScheme, at point: CGPoint? = nil, change: () -> Void) {
        guard let window = NSApp.keyWindow, let view = window.contentView else {
            change()
            return
        }
        let mouse = window.mouseLocationOutsideOfEventStream
        let size = view.bounds.size
        let start = point ?? CGPoint(x: mouse.x, y: size.height - mouse.y)
        origin = CGPoint(x: min(max(start.x, 0), size.width), y: min(max(start.y, 0), size.height))
        let far = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
            .map { hypot($0.x - origin.x, $0.y - origin.y) }.max() ?? 2000
        generation += 1
        let mine = generation
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            oldScheme = scheme
            radius = 0
            isPouring = true
        }
        change()
        withAnimation(.timingCurve(0.7, 0, 0.2, 1, duration: 0.9)) {
            radius = far + 20
        } completion: { [weak self] in
            guard let self, self.generation == mine else { return }
            self.isPouring = false
        }
    }
}

/// The old look's mask: everything but the growing circle.
struct FloodMask: View {
    let flood: ThemeFlood

    var body: some View {
        ZStack {
            Rectangle()
            Circle()
                .frame(width: flood.radius * 2, height: flood.radius * 2)
                .position(flood.origin)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}
