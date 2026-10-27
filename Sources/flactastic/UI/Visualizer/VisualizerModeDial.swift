import SwiftUI
import AppKit

/// The visualizer's mode switcher: a dial that turns in from the left edge.
/// Moving the pointer to the edge opens it. Scroll, drag or ↑/↓ turn it, and
/// the visualizer follows as it turns; moving off the dial, releasing a drag
/// or pressing Return leaves it on that mode. Esc goes back to the mode it
/// opened on.
///
/// The pointer is watched through the window's own mouse-moved events, not
/// SwiftUI hover: hover enter/exit fired against views that were still
/// sliding in, and its state could go stale, leaving the edge unable to
/// reopen the dial until the window was reopened.
///
/// Built to stay smooth while it turns: turning only rotates views that
/// already exist, the tick marks are drawn once, nothing samples the canvas
/// behind it, and the visualizer follows only once the dial pauses on a mode
/// for a moment, so scrolling past three modes doesn't build all three.
struct VisualizerModeDial: View {
    @Binding var mode: VisualizerMode

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isOpen = false
    /// What the dial points at. Leads `mode` by `followDelay` while turning.
    @State private var selection = 0
    /// The mode when the dial opened, for Esc.
    @State private var modeAtOpen: VisualizerMode?
    @State private var followTask: Task<Void, Never>?
    @State private var scrollMonitor: Any?
    @State private var scrollAccumulator: CGFloat = 0
    /// Selection when the current drag began.
    @State private var dragOrigin: Int?

    private static let modes = VisualizerMode.allCases
    /// Degrees between neighboring modes.
    private static let step: Double = 10
    /// How far the open disc reaches into the canvas.
    private static let reach: CGFloat = 240
    private static let hotStripWidth: CGFloat = 18
    /// Trackpad travel, or drag distance, per mode step.
    private static let scrollStep: CGFloat = 36
    private static let dragStep: CGFloat = 44
    /// How long the dial rests on a mode before the visualizer switches to it.
    private static let followDelay: Duration = .milliseconds(160)

    private var turn: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.45)
    }

    var body: some View {
        GeometryReader { geo in
            let diameter = Self.diameter(for: geo.size.height)
            ZStack(alignment: .topLeading) {
                scrim
                knob(height: geo.size.height)
                disc(diameter: diameter)
                    .position(x: Self.reach - diameter / 2, y: geo.size.height / 2)
                pointerTracker(size: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .background(PointerWatcher { point in pointerMoved(to: point, in: geo.size) })
        }
        .background(keyboardShortcuts)
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: reduceMotion ? 0.2 : 0.55), value: isOpen)
        .onAppear { selection = Self.index(of: mode) }
        .onChange(of: mode) { _, newMode in
            if followTask == nil { selection = Self.index(of: newMode) }
        }
        .onChange(of: isOpen) { _, open in
            scrollAccumulator = 0
            if open {
                modeAtOpen = mode
                installScrollMonitor()
            } else {
                removeScrollMonitor()
            }
        }
        .onDisappear { removeScrollMonitor() }
    }

    private static func diameter(for height: CGFloat) -> CGFloat {
        min(960, max(620, height * 1.25))
    }

    // MARK: - Pointer

    /// Opens the dial at the edge strip; lets go once the pointer leaves it.
    private func pointerMoved(to point: CGPoint, in size: CGSize) {
        if !isOpen {
            if point.x >= 0, point.x <= Self.hotStripWidth, point.y >= 0, point.y <= size.height {
                isOpen = true
            }
        } else if dragOrigin == nil, !Self.isOnDial(point, in: size) {
            letGo()
        }
    }

    /// One clear layer over the whole canvas that takes drags and clicks on
    /// the dial. The canvas underneath has nothing to click.
    private func pointerTracker(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard isOpen else { return }
                        if dragOrigin == nil { dragOrigin = selection }
                        // Drag up to bring the next mode to the pointer,
                        // like scrolling down the list.
                        let steps = Int((-value.translation.height / Self.dragStep).rounded())
                        select((dragOrigin ?? selection) + steps)
                    }
                    .onEnded { _ in
                        guard dragOrigin != nil else { return }
                        dragOrigin = nil
                        letGo()
                    }
            )
            .onTapGesture { location in
                if isOpen, !Self.isOnDial(location, in: size) { letGo() }
            }
            .accessibilityHidden(true)
    }

    /// Whether `point` is over the open dial, judged against where the disc
    /// ends up rather than where its opening animation has it now.
    private static func isOnDial(_ point: CGPoint, in size: CGSize) -> Bool {
        let diameter = diameter(for: size.height)
        let center = CGPoint(x: reach - diameter / 2, y: size.height / 2)
        return hypot(point.x - center.x, point.y - center.y) <= diameter / 2 + 16
    }

    // MARK: - Layers

    /// A plain dim, not a blur: a backdrop blur re-samples the whole canvas
    /// every frame the spectrum moves under it.
    private var scrim: some View {
        (colorScheme == .light ? Color.white.opacity(0.6) : Color.black.opacity(0.55))
            .opacity(isOpen ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// The closed dial's edge, peeking in from the left.
    private func knob(height: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(bottomTrailingRadius: 75, topTrailingRadius: 75)
        return shape
            .fill(Theme.surface.opacity(0.85))
            .overlay {
                Canvas { ctx, size in
                    var y: CGFloat = 16
                    while y < size.height - 16 {
                        ctx.fill(Path(CGRect(x: 2, y: y, width: size.width - 6, height: 1)),
                                 with: .color(Theme.textTertiary.opacity(0.6)))
                        y += 8
                    }
                }
            }
            .overlay(shape.strokeBorder(Theme.textPrimary.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 9, x: 4)
            .frame(width: 14, height: 150)
            .offset(y: height / 2 - 75)
            .opacity(isOpen ? 0 : 1)
            .allowsHitTesting(false)
    }

    private func disc(diameter: CGFloat) -> some View {
        let radius = diameter / 2
        return ZStack {
            Circle()
                .fill(colorScheme == .light ? Color(white: 0.98) : Color(white: 0.07))
                .overlay(Circle().strokeBorder(Theme.textPrimary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(colorScheme == .light ? 0.15 : 0.6), radius: 40, x: 24)

            DialTicks(radius: radius)
                .rotationEffect(.degrees(-Double(selection) * Self.step))

            // Each mode's name, inside the ticks at its stop.
            ForEach(Array(Self.modes.enumerated()), id: \.element) { index, item in
                let distance = index - selection
                Text(item.rimLabel)
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(distance == 0 ? Theme.textPrimary : Theme.textTertiary)
                    .fixedSize()
                    .frame(width: 90, alignment: .trailing)
                    .offset(x: radius - 30 - 45)
                    .rotationEffect(.degrees(Double(distance) * Self.step))
                    .opacity(abs(distance) > 5 ? 0 : 1)
            }

            // The marker the selected mode points at.
            DialPointer()
                .fill(Theme.textPrimary)
                .frame(width: 10, height: 16)
                .offset(x: radius + 9)
        }
        .frame(width: diameter, height: diameter)
        .animation(turn, value: selection)
        .rotationEffect(.degrees(isOpen ? 0 : -30))
        .offset(x: isOpen ? 0 : -(Self.reach + 60))
        .opacity(isOpen ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Visualizer mode")
        .accessibilityValue(Self.modes[selection].dialLabel)
    }

    // MARK: - Selection

    private static func index(of mode: VisualizerMode) -> Int {
        modes.firstIndex(of: mode) ?? 0
    }

    /// Point the dial at `index`; the visualizer follows once it rests there.
    private func select(_ index: Int) {
        let clamped = min(Self.modes.count - 1, max(0, index))
        guard clamped != selection else { return }
        selection = clamped
        followTask?.cancel()
        followTask = Task { @MainActor in
            try? await Task.sleep(for: Self.followDelay)
            guard !Task.isCancelled else { return }
            follow()
        }
    }

    /// Switch the visualizer to the mode the dial points at.
    private func follow() {
        followTask?.cancel()
        followTask = nil
        let target = Self.modes[selection]
        if mode != target { mode = target }
    }

    /// Close the dial, staying on the mode it points at.
    private func letGo() {
        isOpen = false
        follow()
    }

    /// Close the dial and go back to the mode it opened on.
    private func cancel() {
        followTask?.cancel()
        followTask = nil
        if let modeAtOpen { mode = modeAtOpen }
        selection = Self.index(of: mode)
        isOpen = false
    }

    // MARK: - Keyboard

    /// ↑/↓ turn the dial while it's open; Return closes it, Esc reverts.
    @ViewBuilder
    private var keyboardShortcuts: some View {
        if isOpen {
            ZStack {
                Button("") { select(selection - 1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { select(selection + 1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("") { letGo() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("") { cancel() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Scrolling

    /// A local event monitor rather than an `NSView` scroll catcher: the dial
    /// is SwiftUI, so an AppKit sibling never lands in the responder chain
    /// that `scrollWheel` walks. Installed only while the dial is open, and
    /// swallows the event so the canvas underneath stays put.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let precise = event.hasPreciseScrollingDeltas
            let delta = event.scrollingDeltaY
            Task { @MainActor in scroll(delta: delta, precise: precise) }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    /// A mouse wheel turns one mode per notch; a trackpad turns one mode per
    /// `scrollStep` of travel. Scrolling down moves down the list.
    private func scroll(delta: CGFloat, precise: Bool) {
        guard delta != 0, isOpen else { return }
        if !precise {
            select(selection + (delta < 0 ? 1 : -1))
            return
        }
        scrollAccumulator += delta
        while abs(scrollAccumulator) >= Self.scrollStep {
            select(selection + (scrollAccumulator < 0 ? 1 : -1))
            scrollAccumulator -= (scrollAccumulator < 0 ? -1 : 1) * Self.scrollStep
        }
    }
}

// MARK: - Pieces

/// Tick marks around the rim: a fine one every 5°, a heavier one every 10°
/// at each mode's stop. Drawn once; turning the dial only rotates it.
private struct DialTicks: View {
    let radius: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for i in 0..<72 {
                let major = i.isMultiple(of: 2)
                let angle = Double(i) * 5 * .pi / 180
                let outer = radius - 4
                let inner = outer - (major ? 16 : 9)
                var path = Path()
                path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                ctx.stroke(path,
                           with: .color(major ? Theme.textPrimary.opacity(0.45) : Theme.textTertiary.opacity(0.5)),
                           lineWidth: major ? 1.5 : 1)
            }
        }
        .frame(width: radius * 2, height: radius * 2)
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

/// A small triangle pointing left, at the rim.
private struct DialPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
