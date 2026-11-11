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
                    streaming
                    offline(profile)
                    if !server.uploads.items.isEmpty { uploads }
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
                    .toggleStyle(FLSwitchStyle())
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
                    .toggleStyle(FLSwitchStyle())
                    .labelsHidden()
            }
            GroupDivider()
            Row(title: offlineTitle(copies), detail: profile.offlineFolder) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([profile.offlineRoot]) }
                    .buttonStyle(PillButtonStyle())
            }
            if let error = copies.lastError { message(error) }
        }
    }

    private func offlineTitle(_ copies: OfflineCopies) -> String {
        if let p = copies.progress { return "Downloading \(p.done + 1) of \(p.total)" }
        let used = "\(copies.installed.count.formatted()) tracks · \(Self.bytes(copies.usedBytes))"
        return copies.pending > 0 ? "\(used) · \(copies.pending) waiting on the server" : used
    }

    // MARK: Uploads

    private var uploads: some View {
        SettingsGroup(title: "Uploads") {
            ForEach(server.uploads.items) { item in
                if item.id != server.uploads.items.first?.id { GroupDivider() }
                Row(title: item.name, detail: uploadDetail(item)) {
                    if item.status == .failed {
                        Button("Remove") { server.uploads.dismiss(item.id) }
                            .buttonStyle(QuietTextButtonStyle())
                            .help("Stop trying to upload this file. The file stays on this Mac.")
                        Button("Retry") { server.uploads.retry(item.id) }
                            .buttonStyle(PillButtonStyle())
                    }
                }
            }
            if server.uploads.items.contains(where: { $0.status == .done }) {
                GroupDivider()
                HStack {
                    Spacer()
                    Button("Clear Finished") { server.uploads.clearFinished() }
                        .buttonStyle(QuietTextButtonStyle())
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
            }
        }
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
                        Button("Revoke") { Task { await revoke(device) } }
                            .buttonStyle(PillButtonStyle())
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
        do {
            try await server.revoke(device)
            await loadDevices()
        } catch {
            devicesError = (error as? LocalizedError)?.errorDescription
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
