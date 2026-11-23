import AppKit
import SwiftUI

/// Settings › Library: which library is open (this Mac's folder or a server
/// account), and the way to add either.
struct LibrarySourceGroup: View {
    @Environment(ServerSession.self) private var server
    @Environment(Settings.self) private var settings
    @Environment(PlayerState.self) private var player
    let openFolder: () -> Void
    @State private var connecting = false

    var body: some View {
        SettingsGroup(title: "Library") {
            SourceRow(icon: "folder.fill", title: "This Mac",
                      detail: settings.lastRootPath ?? "No folder chosen",
                      isActive: !server.isActive) { switchToLocal() }
            ForEach(server.profiles) { profile in
                GroupDivider()
                SourceRow(icon: "server.rack", title: profile.label, detail: profile.address.label,
                          isActive: server.activeID == profile.id, action: "Connect") { switchTo(profile) }
            }
            GroupDivider()
            HStack(spacing: 8) {
                Spacer()
                Button("Choose Folder…") { openFolder() }
                    .buttonStyle(PillButtonStyle())
                Button("Connect to Server…") {
                    player.flushPending()
                    connecting = true
                }
                    .buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
        }
        .sheet(isPresented: $connecting) { ConnectServerSheet() }
    }

    private func switchToLocal() {
        server.disconnect()
    }

    private func switchTo(_ profile: ServerProfile) {
        guard server.activeID != profile.id else { return }
        server.activate(profile.id)
    }
}

private struct SourceRow: View {
    let icon: String
    let title: String
    let detail: String
    let isActive: Bool
    var action = "Open"
    let perform: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                } else if hovering {
                    Text(action)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The open server account: its state, streaming, offline copies, uploads,
/// devices and password.
struct ServerAccountGroups: View {
    @Environment(ServerSession.self) private var server
    @State private var devices: [ServerDevice] = []
    @State private var devicesError: String?
    /// Devices whose Revoke is in flight, so a second click doesn't send it twice.
    @State private var revoking: Set<UUID> = []
    /// While the offline folder is changing (and its files moving).
    @State private var changingFolder = false
    @State private var folderMessage: String?
    /// Every queued file, not just failures.
    @State private var showsUploadFiles = false
    @State private var password = ""
    @State private var current = ""
    @State private var new = ""
    @State private var accountMessage: String?
    @State private var busy = false
    @State private var confirmCopy = false
    @State private var copied = false

    var body: some View {
        if let profile = server.active {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                SettingsGroup(title: profile.serverName) {
                    statusRow(profile)
                }
                if server.status != .identityChanged {
                    // First while there's anything to say: it's what the
                    // status pill's "Uploading…" opens.
                    if !server.uploads.items.isEmpty { uploads }
                    streaming
                    offline(profile)
                    devicesGroup
                    account(profile)
                }
            }
            .task(id: server.activeID) { await loadDevices() }
        }
    }

    // MARK: Status

    @ViewBuilder
    private func statusRow(_ profile: ServerProfile) -> some View {
        switch server.status {
        case .identityChanged:
            Row(title: "This server's identity changed.",
                detail: "Its key no longer matches the one you confirmed. If you reinstalled it, remove it and connect again.") {
                Button("Remove Server") { server.forget(profile.id) }
                    .buttonStyle(SheetPillStyle(isDestructive: true))
            }
        case .signedOut:
            Row(title: "Signed out", detail: "This Mac was signed out of \(profile.serverName).") {
                HStack(spacing: 8) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .onSubmit { Task { await reauthenticate() } }
                    Button("Sign In") { Task { await reauthenticate() } }
                        .buttonStyle(PillButtonStyle())
                        .disabled(password.isEmpty || busy)
                }
            }
            if let accountMessage { message(accountMessage) }
        default:
            Row(title: statusTitle(profile), detail: storageLine) {
                if server.status == .unreachable {
                    Button("Try Now") { server.reconnectNow() }.buttonStyle(PillButtonStyle())
                }
            }
        }
    }

    private func statusTitle(_ profile: ServerProfile) -> String {
        switch server.status {
        case .unreachable: return "Can't reach \(profile.serverName). Trying again… Offline copies still play."
        case .connecting, .idle: return "Connecting…"
        default:
            switch server.library?.state {
            case .offline?: return "The server's music folder is offline. Browsing still works."
            case .scanning?: return "Scanning…"
            default:
                let n = server.library?.trackCount ?? server.libraryStore.tracks.count
                return "Ready · \(n.formatted()) tracks"
            }
        }
    }

    private var storageLine: String {
        guard let lib = server.library else { return server.active.map { "\($0.username) at \($0.address.label)" } ?? "" }
        let used = Self.bytes(lib.usedBytes)
        if let quota = lib.quotaBytes { return "\(used) of \(Self.bytes(quota)) used" }
        return "\(used) used · \(Self.bytes(lib.freeBytes)) free"
    }

    // MARK: Streaming

    private var streaming: some View {
        SettingsGroup(title: "Streaming") {
            Row(title: "Quality", detail: "Follows you to your other devices. Offline copies always play as they are.") {
                Picker("Quality", selection: Binding(get: { server.prefs.streamQuality },
                                                     set: { q in Task { await server.prefs.setStreamQuality(q) } })) {
                    ForEach(StreamQuality.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(server.serverInfo?.transcoding == false)
            }
        }
    }

    // MARK: Offline copies

    private func offline(_ profile: ServerProfile) -> some View {
        let copies = server.offline
        return SettingsGroup(title: "Offline Copies") {
            Row(title: "Whole Library", detail: "Or keep albums and playlists offline from their menus.") {
                Toggle("Whole Library", isOn: Binding(get: { copies.selection.everything }, set: { copies.setEverything($0) }))
                    .toggleStyle(FLSwitchStyle(hiddenLabel: "Whole Library"))
                    .labelsHidden()
            }
            GroupDivider()
            Row(title: "Lossless Only", detail: "Leave MP3 and AAC files on the server.") {
                Toggle("Lossless Only", isOn: Binding(
                    get: { copies.selection.filter.excludedFormats.isSuperset(of: [.mp3, .aac]) },
                    set: { on in
                        var f = copies.selection.filter
                        f.excludedFormats = on ? f.excludedFormats.union([.mp3, .aac]) : f.excludedFormats.subtracting([.mp3, .aac])
                        copies.setFilter(f)
                    }))
                    .toggleStyle(FLSwitchStyle(hiddenLabel: "Lossless Only"))
                    .labelsHidden()
            }
            GroupDivider()
            Row(title: changingFolder ? "Moving your music…" : offlineTitle(copies), detail: profile.offlineFolder) {
                HStack(spacing: Theme.Spacing.sm) {
                    Button("Change…") { changeFolder(profile) }
                        .buttonStyle(PillButtonStyle())
                        .disabled(changingFolder)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([profile.offlineRoot]) }
                        .buttonStyle(PillButtonStyle())
                }
            }
            if let folderMessage { message(folderMessage) }
            if let error = copies.lastError { message(error) }
        }
    }

    /// Picks a new offline folder, then asks whether the music moves with it.
    private func changeFolder(_ profile: ServerProfile) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = profile.offlineRoot.deletingLastPathComponent()
        panel.prompt = "Use Folder"
        panel.message = "Choose where this Mac keeps music from \(profile.serverName)."
        guard panel.runModal() == .OK, let url = panel.url,
              url.standardizedFileURL.path != profile.offlineRoot.standardizedFileURL.path else { return }

        let alert = NSAlert()
        alert.messageText = "Move your music to “\(url.lastPathComponent)”?"
        alert.informativeText = "Offline copies and music that's only on this Mac move with it, so nothing downloads again.\n\nIf you don't move it, offline copies download again into the new folder, and music only on this Mac stays in the old folder and leaves the library."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Don't Move")
        alert.addButton(withTitle: "Cancel")
        let answer = alert.runModal()
        guard answer != .alertThirdButtonReturn else { return }
        let moving = answer == .alertFirstButtonReturn

        changingFolder = true
        folderMessage = nil
        Task {
            defer { changingFolder = false }
            do {
                let left = try await server.changeOfflineFolder(to: url, moving: moving)
                if !moving { server.offline.refresh() }
                if left > 0 {
                    folderMessage = "\(CountText.of(left, "item")) stayed in the old folder because the new one already has something with the same name."
                }
            } catch {
                folderMessage = error.localizedDescription
            }
        }
    }

    private func offlineTitle(_ copies: OfflineCopies) -> String {
        if let p = copies.progress { return "Downloading \(p.done + 1) of \(p.total)" }
        let used = "\(copies.installed.count.formatted()) tracks · \(Self.bytes(copies.usedBytes))"
        return copies.pending > 0 ? "\(used) · \(copies.pending) waiting on the server" : used
    }

    // MARK: Uploads

    /// One summary row: what's uploading now (song and artist), how far the
    /// queue is, Pause/Resume. Failures are always listed; every file only
    /// on request.
    private var uploads: some View {
        let queue = server.uploads
        return SettingsGroup(title: "Uploads") {
            VStack(alignment: .leading, spacing: 10) {
                Row(title: uploadHeadline(queue), detail: uploadSummary(queue)) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Button(showsUploadFiles ? "Hide Files" : "Show Files") {
                            withAnimation(.easeOut(duration: 0.2)) { showsUploadFiles.toggle() }
                        }
                        .buttonStyle(QuietTextButtonStyle())
                        if queue.isBusy {
                            Button(queue.isPaused ? "Resume" : "Pause") {
                                if queue.isPaused { queue.resumeSending() } else { queue.pause() }
                            }
                            .buttonStyle(PillButtonStyle())
                        }
                    }
                }
                if queue.totalBytes > 0, queue.isBusy {
                    UploadProgressBar(fraction: Double(queue.sentBytes) / Double(queue.totalBytes))
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.bottom, 4)
                        .accessibilityLabel("Upload progress")
                        .accessibilityValue("\(Int(Double(queue.sentBytes) / Double(queue.totalBytes) * 100)) percent")
                }
            }
            ForEach(showsUploadFiles ? queue.items : queue.failed) { item in
                GroupDivider()
                Row(title: uploadTitle(item), detail: uploadDetail(item)) {
                    if item.status == .failed {
                        Button("Remove") { queue.dismiss(item.id) }
                            .buttonStyle(QuietTextButtonStyle())
                            .help("Stop trying to upload this file. The file stays on this Mac.")
                        Button("Retry") { queue.retry(item.id) }
                            .buttonStyle(PillButtonStyle())
                    }
                }
            }
            if showsUploadFiles, queue.doneCount > 0 {
                GroupDivider()
                HStack {
                    Spacer()
                    Button("Clear Finished") { queue.clearFinished() }
                        .buttonStyle(QuietTextButtonStyle())
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
            }
        }
    }

    /// The song uploading now, or why nothing is.
    private func uploadHeadline(_ queue: ServerUploads) -> String {
        if queue.isBusy {
            switch queue.hold {
            case .paused?: return "Uploads paused"
            case .streaming?: return "Waiting while you stream"
            case nil: break
            }
        }
        if let first = queue.current.first {
            let more = queue.current.count > 1 ? " and 1 more" : ""
            return uploadTitle(first) + more
        }
        if queue.isBusy { return "Getting ready…" }
        if !queue.failed.isEmpty { return "\(CountText.of(queue.failed.count, "file")) didn't upload" }
        return "All uploaded"
    }

    private func uploadSummary(_ queue: ServerUploads) -> String {
        var parts = ["\(queue.doneCount.formatted()) of \(CountText.of(queue.items.count, "file"))"]
        if queue.totalBytes > 0 {
            parts.append("\(Self.bytes(queue.sentBytes)) of \(Self.bytes(queue.totalBytes))")
        }
        if queue.laneCount > 1, queue.hold == nil, queue.isBusy { parts.append("2 at a time") }
        return parts.joined(separator: " · ")
    }

    /// "Title — Artist" once the tags are read, else the file name.
    private func uploadTitle(_ item: ServerUploads.Item) -> String {
        guard let song = server.uploads.song(item) else { return item.name }
        return song.artist.map { "\(song.title) — \($0)" } ?? song.title
    }

    private func uploadDetail(_ item: ServerUploads.Item) -> String {
        switch item.status {
        case .waiting: return "Waiting"
        case .hashing: return "Checking the file"
        case .sending: return "Uploading \(Int(item.fraction * 100))%"
        case .done: return "Filed as \(item.relativePath ?? item.name)"
        case .failed: return item.error ?? "Didn't upload"
        }
    }

    // MARK: Devices

    private var devicesGroup: some View {
        SettingsGroup(title: "Devices") {
            ForEach(devices) { device in
                if device.id != devices.first?.id { GroupDivider() }
                Row(title: device.current ? "\(device.name) (this Mac)" : device.name,
                    detail: "Last seen \(device.lastSeen.formatted(.relative(presentation: .named)))") {
                    if !device.current {
                        Button(revoking.contains(device.id) ? "Revoking…" : "Revoke") { Task { await revoke(device) } }
                            .buttonStyle(PillButtonStyle())
                            .disabled(revoking.contains(device.id))
                    }
                }
            }
            if let devicesError { message(devicesError) }
        }
    }

    // MARK: Account

    private func account(_ profile: ServerProfile) -> some View {
        SettingsGroup(title: "Account") {
            Row(title: "Change Password", detail: "Signs out your other devices.") {
                HStack(spacing: 8) {
                    SecureField("Current", text: $current).textFieldStyle(.roundedBorder).frame(width: 110)
                    SecureField("New", text: $new).textFieldStyle(.roundedBorder).frame(width: 110)
                    Button("Change") { Task { await changePassword() } }
                        .buttonStyle(PillButtonStyle())
                        .disabled(current.isEmpty || new.utf8.count < 8 || busy)
                }
            }
            if let accountMessage { message(accountMessage) }
            GroupDivider()
            Row(title: "Copy This Mac's Customisation",
                detail: !server.userData.isSupported ? "This server can't keep customisation yet."
                    : copied ? "Copied." : "Artist profiles, spines, genres, Home and the look, once.") {
                Button("Copy…") { confirmCopy = true }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!server.userData.isSupported || busy)
            }
            .confirmationDialog("Copy this Mac's customisation to \(profile.serverName)?", isPresented: $confirmCopy) {
                Button("Copy") {
                    Task {
                        busy = true
                        await server.userData.copyFromThisMac()
                        busy = false
                        copied = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Artist profiles are added for artists that have none here. Spine logos, Edit Spine, genres, Home and the look replace this account's.")
            }
            GroupDivider()
            Row(title: "Disconnect", detail: "Back to this Mac's folder. You stay signed in.") {
                Button("Disconnect") { server.disconnect() }
                    .buttonStyle(SheetPillStyle())
            }
            GroupDivider()
            Row(title: "Sign Out", detail: "Offline copies stay in their folder.") {
                Button("Sign Out") { Task { await server.signOut(profile.id) } }
                    .buttonStyle(SheetPillStyle(isDestructive: true))
            }
        }
    }

    // MARK: Work

    private func loadDevices() async {
        guard server.isActive, server.status != .signedOut, server.status != .identityChanged else { return }
        do {
            devices = try await server.devices()
            devicesError = nil
        } catch {
            devicesError = (error as? LocalizedError)?.errorDescription
        }
    }

    private func revoke(_ device: ServerDevice) async {
        guard revoking.insert(device.id).inserted else { return }
        defer { revoking.remove(device.id) }
        do {
            try await server.revoke(device)
            devicesError = nil
            await loadDevices()
        } catch {
            devicesError = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't revoke \(device.name). Try again."
        }
    }

    private func changePassword() async {
        busy = true
        defer { busy = false }
        do {
            try await server.changePassword(current: current, new: new)
            accountMessage = "Password changed. Your other devices were signed out."
            current = ""
            new = ""
            await loadDevices()
        } catch {
            accountMessage = (error as? LocalizedError)?.errorDescription
        }
    }

    private func reauthenticate() async {
        busy = true
        defer { busy = false }
        do {
            try await server.reauthenticate(password: password)
            password = ""
            accountMessage = nil
        } catch {
            accountMessage = (error as? LocalizedError)?.errorDescription
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.qualityLow)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.sm)
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

/// The queue's progress: a 3pt ink capsule on a hairline track.
private struct UploadProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.textPrimary.opacity(0.1))
                Capsule().fill(Theme.textPrimary)
                    .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                    .animation(.easeOut(duration: 0.3), value: fraction)
            }
        }
        .frame(height: 3)
    }
}

/// Title and detail on the left, a control on the right.
private struct Row<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            control()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }
}
