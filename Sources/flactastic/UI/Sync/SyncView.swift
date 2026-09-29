import SwiftUI

/// The Sync window, opened from **File → Sync…**.
///
/// The same content also lives in Settings ▸ Devices. Both share one
/// `SyncModel`; it reference-counts `begin()/end()`, so networking runs only
/// while at least one of them is on screen.
struct SyncView: View {
    @Environment(SyncModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    FLPageHeader(eyebrow: "Library", title: "Sync")
                    Text("Copy your library to and from your other devices over Wi-Fi. "
                       + "Nothing leaves your network.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                SyncContent()
            }
            .padding(Theme.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(minWidth: 560, minHeight: 520)
        .background(Theme.background)
        .onAppear { model.begin() }
        .onDisappear { model.end() }
    }
}

/// Notices, direction, devices, pairing and progress — everything except the
/// page chrome, so the window and the Devices tab render identically.
struct SyncContent: View {
    @Environment(SyncModel.self) private var model
    @Environment(LibraryStore.self) private var library

    /// The peer whose pairing sheet is open, if any.
    @State private var pairingTarget: DiscoveredPeer?

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            if library.rootURL == nil {
                notice("Open a music folder before syncing.")
            }
            if let failure = model.advertiser.failureMessage {
                notice(failure)
            }
            if let error = model.errorMessage {
                notice(error, isError: true) { model.errorMessage = nil }
            }

            devicesGroup
            directionGroup
            pairingGroup

            if model.phase != .idle {
                statusGroup
            }
        }
        .sheet(item: $pairingTarget) { peer in
            PairingCodeEntrySheet(peer: peer) { code in
                model.pair(with: peer, code: code)
                pairingTarget = nil
            } onCancel: {
                pairingTarget = nil
            }
        }
        .sheet(isPresented: Binding(
            get: { if case .awaitingApproval = model.phase { return true } else { return false } },
            set: { if !$0 { model.declinePlan() } }
        )) {
            if case .awaitingApproval(let plan) = model.phase {
                SyncPlanSheet(plan: plan) { selection in
                    model.approvePlan(selection)
                } onCancel: {
                    model.declinePlan()
                }
            }
        }
    }

    // MARK: - Devices

    /// Paired devices first (online or not), then anything nearby that isn't
    /// paired yet — one list, so it doubles as the "synced devices" view.
    private var devicesGroup: some View {
        let online = model.rows.sorted { $0.isPaired && !$1.isPaired }
        let offline = model.offlinePairedPeers
        let isEmpty = online.isEmpty && offline.isEmpty

        return SettingsGroup(title: "Devices") {
            if isEmpty {
                HStack(spacing: Theme.Spacing.md) {
                    if model.browser.isBrowsing {
                        ProgressView().controlSize(.small)
                    }
                    Text("Looking for other devices running FLACtastic on this network…")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }

            ForEach(Array(online.enumerated()), id: \.element.id) { index, row in
                if index > 0 { GroupDivider() }
                SyncPeerRow(
                    name: row.displayName,
                    kind: row.peer.kind,
                    subtitle: subtitle(for: row),
                    isPaired: row.isPaired,
                    isOnline: true,
                    isBusy: model.activePeerID == row.id || model.pairingPeerID == row.id,
                    isEnabled: row.peer.isCompatible && library.rootURL != nil,
                    primaryTitle: row.isPaired ? "Sync" : "Pair…",
                    onPrimary: {
                        if row.isPaired { model.sync(with: row) } else { pairingTarget = row.peer }
                    },
                    onForget: row.isPaired ? { model.forget(deviceID: row.id) } : nil
                )
            }

            ForEach(Array(offline.enumerated()), id: \.element.id) { index, peer in
                if index > 0 || !online.isEmpty { GroupDivider() }
                SyncPeerRow(
                    name: peer.displayName,
                    kind: peer.kind,
                    subtitle: "Not on this network · "
                        + SyncPeerStore.lastSyncedDescription(peer.lastSyncedAt),
                    isPaired: true,
                    isOnline: false,
                    isBusy: false,
                    isEnabled: false,
                    primaryTitle: "Sync",
                    onPrimary: {},
                    // Forgetting has to stay reachable for a device that is
                    // switched off — otherwise a lost phone can never be
                    // revoked from here.
                    onForget: { model.forget(deviceID: peer.deviceID) }
                )
            }
        }
    }

    private func subtitle(for row: SyncModel.PeerRow) -> String {
        if !row.peer.isCompatible {
            return "Needs a matching version of FLACtastic"
        }
        if !row.isPaired {
            return row.peer.isPairingOpen ? "Showing a pairing code" : "Not paired yet"
        }
        return SyncPeerStore.lastSyncedDescription(row.lastSyncedAt)
    }

    // MARK: - Direction

    private var directionGroup: some View {
        @Bindable var model = model
        return SettingsGroup(title: "Direction") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                FLPillToggle(selection: $model.direction, segments: [
                    .text(SyncDirection.push, "Send to the other device"),
                    .text(SyncDirection.pull, "Get from the other device"),
                ])
                // One direction per run, deliberately: it keeps "what is about
                // to happen to my files" answerable in a single sentence.
                // Syncing both ways is two runs.
                Text(model.direction == .push
                     ? "Files here that the other device is missing will be copied to it."
                     : "Files on the other device that are missing here will be copied to this Mac.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Pairing

    private var pairingGroup: some View {
        SettingsGroup(title: "Pair this Mac") {
            if let code = model.gatekeeper.activeCode, model.gatekeeper.isPairingOpen {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text(formatted(code))
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .tracking(6)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                    Text("Type this code on your other device. It works once, and expires shortly.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Stop") { model.closePairingCode() }
                        .buttonStyle(PillButtonStyle())
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.gatekeeper.isLockedOut {
                Text("Too many failed pairing attempts. Try again in "
                   + "\(model.gatekeeper.lockoutSecondsRemaining) seconds.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pairing code")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Shows an eight-digit code for another device to enter.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Show Code") { model.openPairingCode() }
                        .buttonStyle(PillButtonStyle())
                        .disabled(!model.advertiser.isAdvertising)
                        .opacity(model.advertiser.isAdvertising ? 1 : 0.4)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }
        }
    }

    /// "1234 5678" — grouped so it can be read aloud across a room without
    /// losing your place.
    private func formatted(_ code: String) -> String {
        let midpoint = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<midpoint]) \(code[midpoint...])"
    }

    // MARK: - Status

    private var statusGroup: some View {
        SettingsGroup(title: "Status") {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                switch model.phase {
                case .idle, .awaitingApproval:
                    EmptyView()

                case .preparing(let fraction):
                    progressBar(fraction)
                    // Hashing a large library takes minutes on a first run, so
                    // say what is happening rather than showing a bare bar.
                    HStack {
                        Text("Checking your library…")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        cancelButton
                    }

                case .transferring(let progress):
                    progressBar(progress.fraction)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(progress.completedFiles) of \(progress.totalFiles) files")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textSecondary)
                            if let name = progress.currentFileName {
                                Text(name)
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        cancelButton
                    }

                case .finished(let summary):
                    Text(summaryText(summary))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)

                case .failed(let message):
                    Text(message)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { model.cancelRun() }
            .buttonStyle(PillButtonStyle())
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.divider)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.15), value: fraction)
    }

    private func summaryText(_ summary: SyncSession.Summary) -> String {
        if summary.tracksTransferred == 0 && summary.playlistsTransferred == 0 {
            return "Already up to date."
        }
        var parts: [String] = []
        if summary.tracksTransferred > 0 {
            parts.append("\(summary.tracksTransferred) track\(summary.tracksTransferred == 1 ? "" : "s")")
        }
        if summary.playlistsTransferred > 0 {
            parts.append("\(summary.playlistsTransferred) playlist\(summary.playlistsTransferred == 1 ? "" : "s")")
        }
        var text = "Synced " + parts.joined(separator: " and ")
        text += " · " + ByteCountFormatter.string(fromByteCount: summary.bytesTransferred, countStyle: .file)
        if !summary.failures.isEmpty {
            // Individual failures don't abort a run, so they'd otherwise be
            // invisible — a sync that silently skipped nine files should not
            // read as a clean success.
            text += " · \(summary.failures.count) failed"
        }
        return text
    }

    // MARK: - Notice

    @ViewBuilder
    private func notice(_ message: String, isError: Bool = false, onDismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(isError ? Theme.qualityMid : Theme.textTertiary)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
    }
}
