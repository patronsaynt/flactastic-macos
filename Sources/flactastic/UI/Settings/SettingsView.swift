import SwiftUI
import AppKit

// MARK: - SettingsView

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Settings.self) private var settings
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(ListeningStore.self) private var listening
    @Environment(PlayerState.self) private var player
    @Environment(DebugState.self) private var debugState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // The logo, small, then the sections as a rail of words, like
            // the app's top bar; close on the right.
            HStack(spacing: 16) {
                Wordmark(height: 13)
                    .opacity(0.9)
                    .accessibilityLabel("FLACtastic")
                Rectangle()
                    .fill(Theme.divider)
                    .frame(width: 1, height: 14)
                SettingsTabBar(tabs: visibleTabs, selectedTab: $selectedTab)
                    .padding(.leading, -8)
                Spacer(minLength: Theme.Spacing.md)
                SheetCloseButton { dismiss() }
            }
            .padding(.leading, 26)
            .padding(.trailing, 18)
            .padding(.top, 18)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 30) {
                    Text(selectedTab.rawValue)
                        .font(.system(size: 40, weight: .heavy))
                        .tracking(-1.6)
                        .foregroundStyle(Theme.textPrimary)
                    Group {
                        switch selectedTab {
                        case .general:
                            GeneralSettingsPane(openFolder: openFolder)
                        case .audio:
                            AudioSettingsPane()
                        case .connections:
                            ConnectionsSettingsPane()
                        case .devices:
                            DevicesSettingsPane()
                        case .appearance:
                            AppearanceSettingsPane()
                        case .visualizer:
                            VisualizerSettingsPane()
                        case .debug:
                            DebugSettingsPane()
                        }
                    }
                    .transition(.opacity)
                }
                .id(selectedTab)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 34)
                .padding(.top, 22)
                .padding(.bottom, 34)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 800, height: 680)
        .background(Theme.surface)
        .onChange(of: debugState.debuggingEnabled) { _, enabled in
            if !enabled && selectedTab == .debug { selectedTab = .general }
        }
    }

    /// Debug joins the rail only while Enable Debugging is on.
    private var visibleTabs: [SettingsTab] {
        SettingsTab.allCases.filter { $0 != .debug || debugState.debuggingEnabled }
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
    case devices     = "Devices"
    case appearance  = "Appearance"
    case visualizer  = "Visualizer"
    case debug       = "Debug"
    var id: String { rawValue }
}

// MARK: - Tab bar

private struct SettingsTabBar: View {
    let tabs: [SettingsTab]
    @Binding var selectedTab: SettingsTab
    @Namespace private var tabAnimation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabButton(tab)
                    .transition(.opacity.combined(with: .offset(x: -8)))
            }
        }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.4), value: tabs)
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.25)) {
                selectedTab = tab
            }
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule()
                            .fill(Theme.textPrimary)
                            .frame(height: 2)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 2)
                            .matchedGeometryEffect(id: "activeSettingsTab", in: tabAnimation)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Shared primitives

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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle(label, isOn: $isOn)
                .toggleStyle(FLSwitchStyle())
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
    @Environment(DebugState.self) private var debugState
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

            // Developer ────────────────────────────────────────────────────
            SettingsGroup(title: "Developer") {
                ToggleRow(
                    label: "Enable Debugging",
                    subtitle: "Shows the Debug tab, with switches for testing FLACtastic.",
                    isOn: Binding(
                        get: { debugState.debuggingEnabled },
                        set: { debugState.debuggingEnabled = $0 }
                    )
                )
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
    @Environment(Settings.self) private var settings

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
                        // AirPlay receivers come and go with the route, so
                        // they're picked from the player bar instead.
                        ForEach(audioOutput.devices.filter { !$0.isAirPlay }) { device in
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

            // Network Speakers ─────────────────────────────────────────────
            SettingsGroup(title: "Network Speakers") {
                PickerRow(
                    label: "Streaming Quality",
                    subtitle: "Network speakers fetch the original file and buffer it, so playback holds up on busy Wi-Fi. Lower this only if a speaker stutters or can't play hi-res files. Applies the next time you connect."
                ) {
                    Picker("", selection: Binding(
                        get: { settings.networkStreamQuality },
                        set: { settings.networkStreamQuality = $0 }
                    )) {
                        ForEach(NetworkStreamQuality.allCases) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
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
    @State private var showsGenreGroups = false
    @State private var showsHomeSections = false

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

            // Home ─────────────────────────────────────────────────────────
            SettingsGroup(title: "Home") {
                ToggleRow(
                    label: "Arrange Automatically",
                    subtitle: "Show Home's sections in their designed order. Turn off to choose which appear, and where.",
                    isOn: $settings.homeArrangesAutomatically
                )
                GroupDivider()
                PickerRow(
                    label: "Home Sections",
                    subtitle: "Reorder or hide Recommended for today, Recently played, Mixes and the rest."
                ) {
                    Button("Customize…") { showsHomeSections = true }
                        .buttonStyle(PillButtonStyle())
                }
                .disabled(settings.homeArrangesAutomatically)
                .opacity(settings.homeArrangesAutomatically ? 0.4 : 1)
            }
            .sheet(isPresented: $showsHomeSections) { HomeSectionsSheet() }

            // Library View ─────────────────────────────────────────────────
            // Grid/list layout is chosen in-page on the Collection and
            // Playlists tabs now, so it no longer appears here.
            SettingsGroup(title: "Library View") {
                ToggleRow(
                    label: "Show All Artists",
                    subtitle: "Also list artists who only appear as features on other artists' releases.",
                    isOn: $settings.showAllArtists
                )
                GroupDivider()
                ToggleRow(
                    label: "Hide Singles in Albums",
                    subtitle: "Leave releases with fewer than three tracks out of the Albums view. They still show on artist pages and in search.",
                    isOn: $settings.hideSinglesInAlbums
                )
                GroupDivider()
                ToggleRow(
                    label: "Clear Case Look",
                    subtitle: "Draw the Albums rack's CDs in clear plastic cases that catch the light as you move over them.",
                    isOn: $settings.clearCaseLook
                )
            }

            // Album Spines ─────────────────────────────────────────────────
            // The rack's spines. Everything after Blur Spine Art shapes the
            // designed inserts, so it rests while another style is on.
            SettingsGroup(title: "Album Spines") {
                PickerRow(
                    label: "Spine Style",
                    subtitle: "Designed gives every album its own printed insert, in a face picked by genre. Art + Title and Art Only show the cover's art down the spine."
                ) {
                    Picker("", selection: $settings.spineStyle) {
                        ForEach(SpineStyle.allCases) { Text($0.label).tag($0) }
                    }
                }
                GroupDivider()
                ToggleRow(
                    label: "Use Spine Scans",
                    subtitle: "When an album's folder has a spine image (spine.jpg or similar), show that real printed spine instead.",
                    isOn: $settings.useSpineScans
                )
                GroupDivider()
                ToggleRow(
                    label: "Blur Spine Art",
                    subtitle: "Soften the album art on each spine. Off shows the art as printed.",
                    isOn: $settings.blurSpineArt
                )
                designedRows
            }
            .sheet(isPresented: $showsGenreGroups) { GenreGroupsSheet() }

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

/// Switches for testing the app. Only shown while Settings → General →
/// Enable Debugging is on, and every switch here is ignored while it's off.
private struct DebugSettingsPane: View {
    @Environment(DebugState.self) private var debugState
    @Environment(Settings.self) private var settings
    @Environment(LyricsRemoteCache.self) private var lyricsCache
    @Environment(ArtistRemoteCache.self) private var artistCache
    @Environment(\.openWindow) private var openWindow

    @State private var artworkBytes: Int?
    @State private var cleared: Set<String> = []

    var body: some View {
        @Bindable var debugState = debugState
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsGroup(title: "First run") {
                ToggleRow(
                    label: "Show onboarding at every launch",
                    subtitle: "Runs the setup flow each time FLACtastic opens, against your real settings and library.",
                    isOn: $debugState.showsOnboardingEveryLaunch
                )
                GroupDivider()
                ToggleRow(
                    label: "Show tutorials on every visit",
                    subtitle: "Each tab shows its tips every time you open it.",
                    isOn: $debugState.showsTutorialsEveryVisit
                )
                GroupDivider()
                actionRow(
                    "Preview onboarding",
                    detail: "Opens the setup flow in its own window, right now.",
                    button: "Preview"
                ) { openWindow(id: "onboarding-debug") }
            }

            SettingsGroup(title: "Library") {
                ToggleRow(
                    label: "Preview an empty library",
                    subtitle: "Home, Collection and Playlists appear as a new user sees them. Your library isn't touched.",
                    isOn: $debugState.previewsEmptyLibrary
                )
            }

            SettingsGroup(title: "Performance") {
                ToggleRow(
                    label: "Performance overlay",
                    subtitle: "Frame rate, frame time and memory in the corner of the window.",
                    isOn: $debugState.showsPerformanceOverlay
                )
            }

            SettingsGroup(title: "Downloads") {
                ToggleRow(
                    label: "Lucida inspector",
                    subtitle: "Opens the Lucida bridge inspector: live phase, web view and logs.",
                    isOn: $debugState.lucidaInspector
                )
                GroupDivider()
                ToggleRow(
                    label: "Show VPN advisory",
                    subtitle: "Shows the VPN reminder when opening Download.",
                    isOn: $settings.showVpnNotice
                )
            }

            SettingsGroup(title: "Caches") {
                actionRow(
                    "Artwork",
                    detail: cleared.contains("artwork")
                        ? "Cleared. Thumbnails rebuild from your files as you browse."
                        : "Downsampled covers and blurred backdrops" + (artworkBytes.map { " · " + Self.size($0) } ?? ""),
                    button: cleared.contains("artwork") ? "Cleared" : "Clear"
                ) {
                    ArtworkImageCache.shared.removeAll()
                    BlurredArtworkCache.shared.removeAll()
                    cleared.insert("artwork")
                }
                GroupDivider()
                actionRow(
                    "Lyrics",
                    detail: cleared.contains("lyrics")
                        ? "Cleared. Lyrics are fetched again as songs play. Lyrics saved into your files stay."
                        : "Fetched lyrics for \(lyricsCache.entries.count) songs · \(Self.size(lyricsCache.fileSize))",
                    button: cleared.contains("lyrics") ? "Cleared" : "Clear"
                ) {
                    lyricsCache.removeAll()
                    cleared.insert("lyrics")
                }
                GroupDivider()
                actionRow(
                    "Artist images",
                    detail: cleared.contains("artists")
                        ? "Cleared. Pictures and banners you set yourself stay."
                        : "Fetched pictures for \(artistCache.entries.count) artists · \(Self.size(artistCache.fileSize))",
                    button: cleared.contains("artists") ? "Cleared" : "Clear"
                ) {
                    artistCache.removeAll()
                    cleared.insert("artists")
                }
            }
        }
        .task {
            artworkBytes = await Task.detached(priority: .utility) {
                ArtworkImageCache.shared.diskUsage()
            }.value
        }
    }

    private func actionRow(_ label: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(button, action: action)
                .buttonStyle(SheetPillStyle())
                .disabled(button == "Cleared")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private extension AppearanceSettingsPane {
    /// Rows that shape designed spines, resting (dimmed, inactive) while
    /// another spine style is on.
    @ViewBuilder
    var designedRows: some View {
        @Bindable var settings = settings
        let designed = settings.spineStyle == .designed
        Group {
            GroupDivider()
            PickerRow(
                label: "Spine Variety",
                subtitle: "Uniform gives every album the same tidy insert. Wild widens the ranges, sets inserts a little askew and borrows faces from neighbouring genres."
            ) {
                Picker("", selection: $settings.spineVariety) {
                    ForEach(SpineVariety.allCases) { Text($0.label).tag($0) }
                }
            }
            GroupDivider()
            PickerRow(
                label: "Shelf Theme",
                subtitle: "Artist Series gives each artist one design, in each album's cover colour. Label House Style gives each record label one design."
            ) {
                Picker("", selection: $settings.shelfTheme) {
                    ForEach(ShelfTheme.allCases) { Text($0.label).tag($0) }
                }
            }
            GroupDivider()
            PickerRow(
                label: "Label Mark",
                subtitle: "The record label at the top or foot of the spine: its logo if you've added one, its initials otherwise."
            ) {
                Picker("", selection: $settings.spineLabelMark) {
                    ForEach(LabelMarkStyle.allCases) { Text($0.label).tag($0) }
                }
            }
            GroupDivider()
            ToggleRow(
                label: "Age Spines With Release Year",
                subtitle: "Older albums' inserts yellow and fade, and their cases pick up fine scuffs.",
                isOn: $settings.ageSpinesWithYear
            )
            GroupDivider()
            PickerRow(
                label: "Genre Groups",
                subtitle: "Which genres share a title face, and which faces each group may use."
            ) {
                Button("Edit Groups…") { showsGenreGroups = true }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .disabled(!designed)
        .opacity(designed ? 1 : 0.4)
    }
}
