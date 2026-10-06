import AVKit
import SwiftUI

/// Player-bar button that opens the speaker picker. Tinted with the accent
/// while audio is going to a network speaker.
struct SpeakerPickerButton: View {
    @Environment(CastManager.self) private var cast
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(cast.activeSpeakerID != nil || isPresented ? Theme.accent : Theme.textTertiary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 26, height: 26)
        .help(cast.activeSpeaker.map { "Playing on \($0.name)" } ?? "Play on a speaker")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SpeakerPickerPopover()
                .environment(cast)
        }
        .onChange(of: isPresented) { _, open in
            open ? cast.beginBrowsing() : cast.endBrowsing()
        }
    }

    private var iconName: String {
        if cast.activeAirPlayDevice != nil { return "airplay.audio" }
        return "hifispeaker"
    }
}

// MARK: - Popover

private struct SpeakerPickerPopover: View {
    @Environment(CastManager.self) private var cast

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Play on")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            currentCard

            if let error = cast.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.qualityLow)
            }

            let others = otherSpeakers
            if !others.isEmpty || cast.activeSpeakerID != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if cast.activeSpeakerID != nil {
                        SpeakerRow(icon: "laptopcomputer", name: "This Mac",
                                   detail: cast.localDevice?.name, isConnecting: false) {
                            cast.selectThisMac()
                        }
                    }
                    ForEach(others) { speaker in
                        SpeakerRow(icon: speaker.isAirPlay ? "airplay.audio" : "hifispeaker",
                                   name: speaker.name,
                                   detail: speaker.detail,
                                   isConnecting: cast.connectingID == speaker.id) {
                            cast.select(speaker)
                        }
                    }
                }
            }

            if cast.isLocalNetworkBlocked {
                localNetworkBlockedNotice
            } else if others.isEmpty {
                HStack(spacing: Theme.Spacing.sm) {
                    if cast.isSearching {
                        ProgressView().controlSize(.small)
                        Text("Looking for speakers…")
                    } else {
                        Text("No network speakers found. Make sure the speaker is on and on the same network as this Mac.")
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider().foregroundStyle(Theme.divider)

            AirPlayPickerRow { cast.airPlayPickerDidClose() }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 300)
    }

    private var localNetworkBlockedNotice: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("FLACtastic can't reach your local network", systemImage: "wifi.exclamationmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text("Turn on FLACtastic in System Settings › Privacy & Security › Local Network, then reopen this menu.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Local Network Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }

    private var otherSpeakers: [SpeakerDevice] {
        cast.speakers.filter { $0.id != cast.activeSpeakerID }
    }

    /// The highlighted "where audio is going now" card.
    private var currentCard: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: currentIcon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(cast.activeSpeaker?.name ?? "This Mac")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Text(currentDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.surfaceElevated)
        )
    }

    private var currentIcon: String {
        guard let speaker = cast.activeSpeaker else { return "laptopcomputer" }
        return speaker.isAirPlay ? "airplay.audio" : "hifispeaker.fill"
    }

    private var currentDetail: String {
        if let status = cast.statusMessage { return status }
        if let quality = cast.activeQualityDescription { return quality }
        return cast.localDevice?.name ?? "This computer"
    }
}

private struct SpeakerRow: View {
    let icon: String
    let name: String
    let detail: String?
    let isConnecting: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if isConnecting || detail != nil {
                        Text(isConnecting ? "Connecting…" : detail ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isConnecting {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(isHovered ? Theme.surfaceHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - System AirPlay picker

/// Row hosting macOS's own AirPlay route picker. AirPlay receivers only
/// become Core Audio devices once macOS routes to them, so this is how the
/// user picks one the first time.
private struct AirPlayPickerRow: View {
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            RoutePicker(onClose: onClose)
                .frame(width: 28, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("AirPlay speakers")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                Text("CD-quality lossless (16-bit / 44.1 kHz)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.sm)
    }
}

private struct RoutePicker: NSViewRepresentable {
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        context.coordinator.onClose = onClose
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            onClose()
        }
    }
}
