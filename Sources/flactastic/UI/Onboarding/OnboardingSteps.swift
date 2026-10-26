import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Welcome

struct OnboardingWelcomeStep: View {
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            OnboardingStepText(
                title: "Your music, properly.",
                subtitle: "FLACtastic plays and organizes the lossless files you own. Setting up takes about a minute."
            )
            Button("Get started", action: onNext)
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Look

struct OnboardingLookStep: View {
    @Environment(Settings.self) private var settings
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            OnboardingStepText(title: "Choose your look", subtitle: "Switch any time in Settings.")
            HStack(spacing: 22) {
                LookTile(title: "Dark", isLight: false, isSelected: !settings.useLightMode) { select(light: false) }
                LookTile(title: "Light", isLight: true, isSelected: settings.useLightMode) { select(light: true) }
            }
            Button("Continue", action: onNext)
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
    }

    private func select(light: Bool) {
        withAnimation(.easeInOut(duration: 0.4)) { settings.useLightMode = light }
    }
}

/// A tiny FLACtastic in one theme: a bar, a row of covers, two lines.
private struct LookTile: View {
    let title: String
    let isLight: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                preview
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isSelected ? Theme.textPrimary : Theme.textPrimary.opacity(0.1),
                                          lineWidth: isSelected ? 2 : 1)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 12)
                HStack(spacing: 8) {
                    Circle()
                        .strokeBorder(isSelected ? Theme.textPrimary : Theme.textTertiary, lineWidth: isSelected ? 5 : 1.5)
                        .frame(width: 16, height: 16)
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) appearance")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeOut(duration: 0.2), value: isSelected)
    }

    private var preview: some View {
        let ink = isLight ? Color.black : Color.white
        return VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(ink.opacity(0.12)).frame(width: 116, height: 12)
                .padding([.top, .leading], 10)
            HStack(spacing: 7) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(ink.opacity([0.22, 0.15, 0.1, 0.18][i]))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(10)
            Capsule().fill(ink.opacity(0.12)).frame(width: 120, height: 6).padding(.leading, 10)
            Capsule().fill(ink.opacity(0.07)).frame(width: 80, height: 6).padding(.leading, 10).padding(.top, 6).padding(.bottom, 12)
        }
        .frame(width: 200, alignment: .leading)
        .background(isLight ? Color(white: 0.96) : Color(white: 0.02))
    }
}

// MARK: - Library

struct OnboardingLibraryStep: View {
    @Environment(Settings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(ListeningStore.self) private var listening
    let onNext: () -> Void

    @State private var isTargeted = false

    private var folderPath: String? { settings.lastRootPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            OnboardingStepText(
                title: "Where does your music live?",
                subtitle: "Pick the folder that holds your music. FLACtastic watches it for changes and never moves a file unless you ask it to."
            )

            if let folderPath {
                OnboardingStatusRow(title: (folderPath as NSString).lastPathComponent, detail: linkedDetail(folderPath)) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 40, height: 40)
                        .background(Theme.textPrimary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } accessory: {
                    Button("Change", action: openFolder)
                        .buttonStyle(QuietTextButtonStyle())
                }
                .transition(.opacity.combined(with: .offset(y: 12)))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    dropZone
                    Button("Create an empty folder for me", action: createEmptyFolder)
                        .buttonStyle(QuietTextButtonStyle())
                        .padding(.leading, -10)
                }
                .transition(.opacity)
            }

            Button("Continue", action: onNext)
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(folderPath == nil)
        }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.5), value: folderPath)
    }

    private var dropZone: some View {
        Button(action: openFolder) {
            VStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textSecondary)
                Text("Choose a folder…")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("or drag one here")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .background(Theme.textPrimary.opacity(isTargeted ? 0.09 : 0.04),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.textPrimary.opacity(isTargeted ? 0.5 : 0.14),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return }
                Task { @MainActor in adoptFolder(url) }
            }
            return true
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    private func linkedDetail(_ path: String) -> String {
        let shown = (path as NSString).abbreviatingWithTildeInPath
        if !library.hasCompletedInitialLoad { return "\(shown) · scanning…" }
        let count = library.tracks.count
        return count == 0 ? "\(shown) · empty, ready for imports" : "\(shown) · \(count.formatted()) tracks"
    }

    private func createEmptyFolder() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("flactastic", isDirectory: true)
            .appendingPathComponent("Music", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            adoptFolder(dir)
        } catch {
            print("[Onboarding] Failed to create music folder: \(error)")
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose your music folder"
        if panel.runModal() == .OK, let url = panel.url {
            adoptFolder(url)
        }
    }

    private func adoptFolder(_ url: URL) {
        settings.lastRootPath = url.path
        library.openFolder(url)
        playlistStore.load(from: url)
        listening.load(from: url)
    }
}

// MARK: - Spotify (optional)

struct OnboardingSpotifyStep: View {
    @Environment(SpotifyAuthController.self) private var spotifyAuth
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 16) {
                OnboardingOptionalTag()
                OnboardingStepText(
                    title: "Bring your playlists over",
                    subtitle: "Connect Spotify to rebuild your playlists from the music you own. This one's optional — you can connect later from Download or Settings."
                )
            }

            OnboardingStatusRow(title: "Spotify", detail: status) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Theme.textPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } accessory: {
                switch spotifyAuth.state {
                case .disconnected:
                    Button("Connect") { Task { await spotifyAuth.connect() } }
                        .buttonStyle(SheetPillStyle())
                case .connecting:
                    ProgressView().controlSize(.small)
                case .connected:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.qualityCD)
                }
            }

            if case .connected = spotifyAuth.state {
                Button("Continue", action: onNext)
                    .buttonStyle(SheetPillStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Skip for now", action: onNext)
                    .buttonStyle(SheetPillStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var status: String {
        switch spotifyAuth.state {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected(let name): return "Connected as \(name)"
        }
    }
}

// MARK: - Done

struct OnboardingDoneStep: View {
    @Environment(Settings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(SpotifyAuthController.self) private var spotifyAuth
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            OnboardingStepText(
                title: "You’re all set",
                subtitle: "Your library is linked and ready. Time to hear it properly."
            )
            VStack(spacing: 0) {
                row("Look", settings.useLightMode ? "Light" : "Dark")
                row("Library", librarySummary)
                row("Spotify", spotifySummary)
            }
            .frame(maxWidth: 480)
            Button("Enter FLACtastic", action: onFinish)
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
    }

    private var librarySummary: String {
        guard let path = settings.lastRootPath else { return "Not linked" }
        let name = (path as NSString).lastPathComponent
        guard library.hasCompletedInitialLoad else { return "\(name) · scanning…" }
        let count = library.tracks.count
        return count == 0 ? "\(name) (empty)" : "\(name) · \(count.formatted()) tracks"
    }

    private var spotifySummary: String {
        if case .connected = spotifyAuth.state { return "Connected" }
        return "Skipped — connect any time"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 14))
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}
