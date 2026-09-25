import SwiftUI
import AppKit

// MARK: - SettingsView

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Settings.self) private var settings
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(ListeningStore.self) private var listening
    @Environment(PlayerState.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // Header: centered wordmark + trailing close button.
            ZStack {
                Wordmark(height: 16)
                    .opacity(0.9)
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, Theme.Spacing.xl)
                }
            }
            .frame(height: 52)

            Divider().foregroundStyle(Theme.divider)

            // Centered tab bar.
            SettingsTabBar(selectedTab: $selectedTab)
                .padding(.vertical, Theme.Spacing.sm + 2)

            Divider().foregroundStyle(Theme.divider)

            // Scrollable content pane.
            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsPane(openFolder: openFolder)
                    case .audio:
                        AudioSettingsPane()
                    case .connections:
                        ConnectionsSettingsPane()
                    case .appearance:
                        AppearanceSettingsPane()
                    case .visualizer:
                        VisualizerSettingsPane()
                    case .debug:
                        DebugSettingsPane()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, Theme.Spacing.lg + 4)
                .padding(.top, Theme.Spacing.lg + 4)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 700, height: 560)
        .background(Theme.surface)
    }

    // ── Folder picker ──────────────────────────────────────────────────────

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose your music folder"
        if panel.runModal() == .OK, let url = panel.url {
            // Commit the outgoing library's in-flight play and save its
            // history before switching roots, then load the new library's.
            player.flushPending()
            listening.save()
            settings.lastRootPath = url.path
            library.openFolder(url)
            playlistStore.load(from: url)
            listening.load(from: url)
        }
    }
}

// MARK: - Tab model

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general     = "General"
    case audio       = "Audio"
    case connections = "Connections"
    case appearance  = "Appearance"
    case visualizer  = "Visualizer"
    case debug       = "Debug"
    var id: String { rawValue }
}

// MARK: - Tab bar

private struct SettingsTabBar: View {
    @Binding var selectedTab: SettingsTab
    @Namespace private var tabAnimation

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                tabButton(tab)
            }
        }
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        } label: {
            Text(tab.rawValue)
                .font(isSelected ? Theme.Font.bodyMedium : Theme.Font.body)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, Theme.Spacing.lg + 2)
                .padding(.vertical, Theme.Spacing.sm)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(Theme.surfaceElevated)
                            .matchedGeometryEffect(id: "activeSettingsTab", in: tabAnimation)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared primitives

/// A titled group of settings rows rendered on a raised surface card.
private struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .kerning(0.6)
                    .padding(.horizontal, 2)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Hair-line divider between rows inside a SettingsGroup.
private struct GroupDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 0.5)
            .padding(.leading, Theme.Spacing.lg)
    }
}

/// Standard label + toggle row for use inside SettingsGroup.
private struct ToggleRow: View {
    let label: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    var body: some View {
        HStack(alignment: subtitle != nil ? .top : .center, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .labelsHidden()
                .disabled(!isEnabled)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - General pane

private struct GeneralSettingsPane: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Settings.self) private var settings
    @Environment(\.debugMode) private var debugMode
    let openFolder: () -> Void

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {

            // Library ──────────────────────────────────────────────────────
            SettingsGroup(title: "Library") {
                HStack(spacing: Theme.Spacing.md) {
                    if let rootURL = library.rootURL {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Theme.textTertiary)
                        Text(rootURL.path)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Image(systemName: "folder")
                            .foregroundStyle(Theme.textTertiary)
                        Text("No folder selected")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Button("Choose Folder…") { openFolder() }
                        .buttonStyle(PillButtonStyle())
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }

            // Navigation ───────────────────────────────────────────────────
            SettingsGroup(title: "Navigation") {
                ToggleRow(
                    label: "Show Download Tab",
                    subtitle: "Show the Download tab in the top navigation bar.",
                    isOn: $settings.showDownloadTab
                )
            }

            // Playback ─────────────────────────────────────────────────────
            SettingsGroup(title: "Playback") {
                ToggleRow(
                    label: "Menu Bar Mini-Player",
                    subtitle: "Show a compact player in the system menu bar.",
                    isOn: $settings.showMenuBarPlayer
                )
                GroupDivider()
                ToggleRow(
                    label: "Auto-Fetch Artist Images",
                    subtitle: "Automatically download artist artwork from Deezer when missing.",
                    isOn: $settings.autoFetchArtistImages
                )
            }

            // Statistics ───────────────────────────────────────────────────
            SettingsGroup(title: "Statistics") {
                CountedPlayThresholdRow()
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
            }

            // Debug (hidden behind debugMode flag) ─────────────────────────
            if debugMode {
                SettingsGroup(title: "Debug") {
                    ToggleRow(
                        label: "Show VPN Advisory",
                        subtitle: "Show a reminder to use a VPN when opening the Downloads tab.",
                        isOn: $settings.showVpnNotice
                    )
                }
            }
        }
    }
}

// MARK: - Counted-play threshold

/// Lets the user choose what percentage of a track must play straight through
/// for it to count as one play (streaming-service style). Backed by
/// `Settings.countedPlayFraction` (0…1); the field edits whole percent (0–100).
private struct CountedPlayThresholdRow: View {
    @Environment(Settings.self) private var settings

    /// Local editing buffer so partial input doesn't fight the clamped store.
    @State private var text: String = ""

    private var percent: Int { Int((settings.countedPlayFraction * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Counted Play Threshold")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Percentage of a track that must play straight through before it counts as a single play. Higher values are stricter; scrubbing or skipping never counts.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.xl)
                HStack(spacing: 2) {
                    TextField("90", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 46)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .onSubmit { commit() }
                    Text("%")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Slider(
                value: Binding(
                    get: { settings.countedPlayFraction },
                    set: { settings.countedPlayFraction = $0 }
                ),
                in: 0...1,
                step: 0.01
            )
            .tint(Theme.accent)
        }
        .onAppear { text = String(percent) }
        // Keep the field in sync when the slider moves it.
        .onChange(of: settings.countedPlayFraction) { _, _ in text = String(percent) }
    }

    /// Parse the field, clamp to 0–100, and write back as a fraction.
    private func commit() {
        let digits = text.filter(\.isNumber)
        let value = Int(digits) ?? percent
        let clamped = min(max(value, 0), 100)
        settings.countedPlayFraction = Double(clamped) / 100.0
        text = String(clamped)
    }
}

// MARK: - Audio pane

private struct AudioSettingsPane: View {
    @Environment(AudioOutputManager.self) private var audioOutput

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {

            // Output Device ────────────────────────────────────────────────
            SettingsGroup(title: "Output Device") {
                PickerRow(label: "Device", subtitle: missingDeviceNote) {
                    Picker("", selection: Binding(
                        get: { audioOutput.selectedDeviceUID ?? "" },
                        set: { audioOutput.selectDevice(uid: $0.isEmpty ? nil : $0) }
                    )) {
                        Text(systemDefaultLabel).tag("")
                        Divider()
                        ForEach(audioOutput.devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                        if audioOutput.isSelectedDeviceMissing, let uid = audioOutput.selectedDeviceUID {
                            Text("Disconnected Device").tag(uid)
                        }
                    }
                }
            }

            // Format ───────────────────────────────────────────────────────
            SettingsGroup(title: "Format") {
                PickerRow(
                    label: "Sample Rate",
                    subtitle: "Every track is resampled to this rate so playback stays gapless. Changing output settings briefly restarts the current track at the same position."
                ) {
                    Picker("", selection: Binding(
                        get: { audioOutput.selectedSampleRate ?? 0 },
                        set: { audioOutput.selectSampleRate($0 == 0 ? nil : $0) }
                    )) {
                        Text(deviceDefaultLabel(audioOutput.currentSampleRate.map(FormatUtils.kilohertzString)))
                            .tag(0.0)
                        Divider()
                        ForEach(rateOptions, id: \.self) { rate in
                            Text(FormatUtils.kilohertzString(rate)).tag(rate)
                        }
                    }
                }
                GroupDivider()
                PickerRow(label: "Bit Depth") {
                    Picker("", selection: Binding(
                        get: { audioOutput.selectedBitDepth ?? 0 },
                        set: { audioOutput.selectBitDepth($0 == 0 ? nil : $0) }
                    )) {
                        Text(deviceDefaultLabel(audioOutput.currentBitDepth.map { "\($0)-bit" }))
                            .tag(0)
                        Divider()
                        ForEach(depthOptions, id: \.self) { bits in
                            Text("\(bits)-bit").tag(bits)
                        }
                    }
                    .disabled(audioOutput.availableBitDepths.isEmpty)
                }
            }

            // Now Outputting ───────────────────────────────────────────────
            SettingsGroup(title: "Now Outputting") {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "hifispeaker.fill")
                        .foregroundStyle(Theme.textTertiary)
                    Text(nowOutputting)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }
        }
    }

    private var systemDefaultLabel: String {
        audioOutput.defaultDevice.map { "System Default (\($0.name))" } ?? "System Default"
    }

    private var missingDeviceNote: String? {
        audioOutput.isSelectedDeviceMissing
            ? "The selected device is disconnected. Using the system default until it's reconnected."
            : nil
    }

    private func deviceDefaultLabel(_ current: String?) -> String {
        current.map { "Device Default (currently \($0))" } ?? "Device Default"
    }

    /// Available options, plus the saved choice if the current device can't
    /// offer it (e.g. pinned DAC unplugged) so the picker never shows blank.
    private var rateOptions: [Double] {
        var rates = audioOutput.availableSampleRates
        if let saved = audioOutput.selectedSampleRate, !rates.contains(saved) { rates.append(saved) }
        return rates.sorted()
    }

    private var depthOptions: [Int] {
        var depths = audioOutput.availableBitDepths
        if let saved = audioOutput.selectedBitDepth, !depths.contains(saved) { depths.append(saved) }
        return depths.sorted()
    }

    private var nowOutputting: String {
        var parts: [String] = []
        if let rate = audioOutput.currentSampleRate { parts.append(FormatUtils.kilohertzString(rate)) }
        if let bits = audioOutput.currentBitDepth { parts.append("\(bits)-bit") }
        let format = parts.joined(separator: " · ")
        let name = audioOutput.effectiveDevice?.name ?? "No output device"
        return format.isEmpty ? name : "\(format) → \(name)"
    }
}

/// Label (+ optional caption) with a trailing menu picker, for SettingsGroup.
private struct PickerRow<Control: View>: View {
    let label: String
    var subtitle: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: subtitle != nil ? .top : .center, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            control()
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }
}

// MARK: - Connections pane

private struct ConnectionsSettingsPane: View {
    @Environment(Settings.self) private var settings
    @Environment(SpotifyAuthController.self) private var spotifyAuth

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {

            // Social ───────────────────────────────────────────────────────
            SettingsGroup(title: "Social") {
                ToggleRow(
                    label: "Discord Rich Presence",
                    subtitle: "Show the currently playing track in your Discord status.",
                    isOn: $settings.discordRichPresenceEnabled
                )
            }

            // Spotify account ──────────────────────────────────────────────
            SettingsGroup(title: "Spotify Account") {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text("Connect your Spotify account to browse and download your own playlists, including private ones, in full.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: Theme.Spacing.md) {
                        switch spotifyAuth.state {
                        case .disconnected:
                            Button("Connect Spotify") {
                                Task { await spotifyAuth.connect() }
                            }
                            .buttonStyle(PillButtonStyle(isPrimary: true))
                        case .connecting:
                            ProgressView().controlSize(.small)
                            Text("Connecting…")
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.textSecondary)
                        case .connected(let name):
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Theme.qualityCD)
                                    .frame(width: 7, height: 7)
                                (Text("Connected as ")
                                    .foregroundStyle(Theme.textSecondary)
                                + Text(name)
                                    .foregroundStyle(Theme.textPrimary)
                                    .fontWeight(.medium))
                                    .font(Theme.Font.body)
                            }
                            Spacer()
                            Button("Disconnect") { spotifyAuth.disconnect() }
                                .buttonStyle(PillButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)

                ToggleRow(
                    label: "Show Liked Songs",
                    subtitle: "Show a Liked Songs entry alongside your playlists on the Playlists download screen.",
                    isOn: $settings.showSpotifyLikedSongs
                )
            }
        }
    }
}

// MARK: - Appearance pane

private struct AppearanceSettingsPane: View {
    @Environment(Settings.self) private var settings

    private let scaleRange: ClosedRange<Double> = 0.9...1.35

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {

            // Theme ────────────────────────────────────────────────────────
            SettingsGroup(title: "Theme") {
                ToggleRow(
                    label: "Light Mode",
                    subtitle: "Switch to a light background throughout the app.",
                    isOn: $settings.useLightMode
                )
            }

            // Library View ─────────────────────────────────────────────────
            // Grid/list layout is chosen in-page on the Collection and
            // Playlists tabs now, so it no longer appears here.
            SettingsGroup(title: "Library View") {
                ToggleRow(
                    label: "Group Albums by Artist",
                    subtitle: "In grid view, cluster albums under their artist.",
                    isOn: $settings.groupByArtist
                )
            }

            // Artwork ──────────────────────────────────────────────────────
            SettingsGroup(title: "Artwork") {
                ToggleRow(label: "Rounded Album Art", isOn: $settings.roundedArtwork)
                GroupDivider()
                ToggleRow(label: "Drop Shadow", isOn: $settings.showArtworkShadow)
            }

            // Animations ───────────────────────────────────────────────────
            SettingsGroup(title: "Animations") {
                ToggleRow(label: "Fade Animations", isOn: $settings.fadeAnimationsEnabled)
                GroupDivider()
                HStack {
                    Text("Fade Direction")
                        .font(Theme.Font.body)
                        .foregroundStyle(settings.fadeAnimationsEnabled ? Theme.textPrimary : Theme.textTertiary)
                    Spacer()
                    Picker("", selection: $settings.fadeAnimationDirection) {
                        ForEach(FadeAnimationDirection.allCases) { dir in
                            Text(dir.label).tag(dir)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(!settings.fadeAnimationsEnabled)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .opacity(settings.fadeAnimationsEnabled ? 1 : 0.4)
            }

            // Interface ────────────────────────────────────────────────────
            SettingsGroup(title: "Interface") {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("UI Scale")
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Scales text and controls throughout the app.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Text("\(Int((settings.uiScale * 100).rounded()))%")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .monospacedDigit()
                    }
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(Theme.textTertiary)
                        Slider(value: $settings.uiScale, in: scaleRange, step: 0.05)
                            .tint(Theme.accent)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(Theme.textTertiary)
                        Button {
                            settings.uiScale = 1.0
                        } label: {
                            Text("Reset")
                                .font(Theme.Font.caption)
                        }
                        .buttonStyle(PillButtonStyle())
                        .disabled(abs(settings.uiScale - 1.0) < 0.001)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }
        }
    }
}

// MARK: - Visualizer pane

private struct VisualizerSettingsPane: View {
    @Environment(Settings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {

            // Lyrics ───────────────────────────────────────────────────────
            SettingsGroup(title: "Lyrics") {
                ToggleRow(
                    label: "Fetch Lyrics from lrclib.net",
                    subtitle: "Enables the Lyrics visualizer mode. Lookups are cached on disk; disable to stay fully offline.",
                    isOn: $settings.lyricsLookupEnabled
                )
                GroupDivider()
                ToggleRow(
                    label: "Save Lyrics to Audio Files",
                    subtitle: "Embed fetched lyrics into the LYRICS tag on each file (Vorbis, ID3v2 USLT, MP4). Other players will pick them up automatically.",
                    isOn: $settings.saveLyricsToFiles,
                    isEnabled: settings.lyricsLookupEnabled
                )
            }
        }
    }
}

// MARK: - Debug pane

private struct DebugSettingsPane: View {
    @Environment(DebugState.self) private var debugState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var debugState = debugState

        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsGroup(title: "Developer Tools") {
                ToggleRow(
                    label: "Debug Lucida",
                    subtitle: "Open the Lucida WebKit bridge inspector — live phase, web view, and navigation/bridge log.",
                    isOn: $debugState.lucidaDebugEnabled
                )
                GroupDivider()
                HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Debug Onboarding")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Replay the first-run onboarding sequence in its own window, against the app's live settings and library.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Preview") { openWindow(id: "onboarding-debug") }
                        .buttonStyle(PillButtonStyle())
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }
        }
    }
}
