import AppKit
import Observation
import SwiftUI

/// The menu bar icon and its popover. A status item with an `NSPopover`
/// rather than SwiftUI's `MenuBarExtra`: that window grows to fit its
/// content but never shrinks back, so closing the queue drawer left the
/// player loose in a too-tall window. The popover takes its size from the
/// SwiftUI content, animates the change, and stays pinned to the icon.
///
/// The icon is in while the app is open, or only while music plays when the
/// person chose that in Settings; it follows both live.
@MainActor
final class MenuBarPlayerController: NSObject {
    private var player: PlayerState?
    private var settings: Settings?
    private var statusItem: NSStatusItem?
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        return popover
    }()

    /// Wires the controller to the app's shared state. Safe to call again
    /// (the launch task can run more than once); only the first call counts.
    func attach(player: PlayerState, settings: Settings, cast: CastManager) {
        guard self.player == nil else { return }
        self.player = player
        self.settings = settings
        // Only what the popover reads: the player, the settings (artwork,
        // volume) and the speaker picker's cast manager.
        let host = NSHostingController(rootView: MenuBarPlayerView()
            .environment(player)
            .environment(settings)
            .environment(cast))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        refresh()
    }

    /// The FLACtastic mark as a template image, so the menu bar colours it
    /// itself: dark on a light bar, light on a dark one, and highlighted
    /// while the popover is open. A music note if the file is missing.
    private static let icon: NSImage? = {
        guard let url = Wordmark.resourceBundle?.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) }
        // Menu bar glyphs sit about 15pt tall; keep the mark's own proportions.
        let height: CGFloat = 15
        image.size = NSSize(width: (height * image.size.width / image.size.height).rounded(), height: height)
        image.isTemplate = true
        return image
    }()

    private var shouldShow: Bool {
        guard let settings, let player else { return false }
        return settings.showMenuBarPlayer && (!settings.menuBarPlayerOnlyWhilePlaying || player.isPlaying)
    }

    /// Adds or removes the icon to match the settings and playback, then
    /// waits for either to change.
    private func refresh() {
        let show = withObservationTracking { shouldShow } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        if show, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = Self.icon
            item.button?.setAccessibilityLabel("FLACtastic player")
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            statusItem = item
        } else if !show, let item = statusItem {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            // Key, so the controls answer the first click and Esc closes it.
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
