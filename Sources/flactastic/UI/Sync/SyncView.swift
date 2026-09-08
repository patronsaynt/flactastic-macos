import SwiftUI

/// The Sync window, opened from **File → Sync…**.
///
/// Sync is a task with a beginning and an end, not a place in the library you
/// browse to, so it lives in a window rather than a tab — the same treatment
/// the Organizer-style one-off operations get. Closing the window is also the
/// off switch: `SyncModel.end()` stops the listener, the browser, and any
/// pairing code, so nothing keeps running on the network once the user is done.
struct SyncView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(\.dismiss) private var dismiss

    @State private var model: SyncModel?
    /// The peer whose pairing sheet is open, if any.
    @State private var pairingTarget: DiscoveredPeer?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Theme.background)
        .onAppear {
            let created = SyncModel(library: library, playlistStore: playlistStore)
            model = created
            created.begin()
        }
        .onDisappear { model?.end() }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ model: SyncModel) -> some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 0) {
            header(model)
            Divider().overlay(Theme.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if library.rootURL == nil {
                        notice("Open a music folder before syncing.")
                    }
                    if let failure = model.advertiser.failureMessage {
                        notice(failure)
                    }
                    if let error = model.errorMessage {
                        notice(error, isError: true) { model.errorMessage = nil }
                    }

                    directionPicker(model)
                    peerList(model)
                    pairingSection(model)
                }
                .padding(Theme.Spacing.xl)
            }

            if model.phase != .idle {
                Divider().overlay(Theme.divider)
                statusBar(model)
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
                SyncPlanSheet(plan: plan) { model.approvePlan() } onCancel: { model.declinePlan() }
            }
        }
    }

    private func header(_ model: SyncModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Sync")
                .font(Theme.Font.title)
                .foregroundStyle(Theme.textPrimary)
            Text("Copy your library to and from your other devices over Wi-Fi. "
               + "Nothing leaves your network.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Spacing.xl)
    }

    // MARK: - Direction

    private func directionPicker(_ model: SyncModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Direction")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
            Picker("", selection: $model.direction) {
                Text("Send to the other device").tag(SyncDirection.push)
                Text("Get from the other device").tag(SyncDirection.pull)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // One direction per run, deliberately: it keeps "what is about to
            // happen to my files" answerable in a single sentence. Syncing both
            // ways is two runs.
            Text(model.direction == .push
                 ? "Files here that the other device is missing will be copied to it."
                 : "Files on the other device that are missing here will be copied to this Mac.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Peers

    @ViewBuilder
    private func peerList(_ model: SyncModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Devices")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if model.browser.isBrowsing {
                    ProgressView().controlSize(.small)
                }
            }

            if model.rows.isEmpty && model.offlinePairedPeers.isEmpty {
                Text("Looking for other devices running FLACtastic on this network…")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, Theme.Spacing.lg)
            }

            ForEach(model.rows) { row in
                SyncPeerRow(
                    name: row.displayName,
                    kind: row.peer.kind,
                    subtitle: subtitle(for: row),
                    isPaired: row.isPaired,
                    isBusy: model.activePeerID == row.id || model.pairingPeerID == row.id,
                    isEnabled: row.peer.isCompatible && library.rootURL != nil,
                    primaryTitle: row.isPaired ? "Sync" : "Pair…",
                    onPrimary: {
                        if row.isPaired { model.sync(with: row) } else { pairingTarget = row.peer }
                    },
                    onForget: row.isPaired ? { model.forget(deviceID: row.id) } : nil
                )
            }

            ForEach(model.offlinePairedPeers) { peer in
                SyncPeerRow(
                    name: peer.displayName,
                    kind: peer.kind,
                    subtitle: "Not on this network",
                    isPaired: true,
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

    // MARK: - Pairing

    @ViewBuilder
    private func pairingSection(_ model: SyncModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Pair this Mac")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)

            if let code = model.gatekeeper.activeCode, model.gatekeeper.isPairingOpen {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(formatted(code))
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .tracking(6)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                    Text("Type this code on your other device. It works once, and expires shortly.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Button("Stop") { model.closePairingCode() }
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            } else if model.gatekeeper.isLockedOut {
                notice("Too many failed pairing attempts. Try again in "
                     + "\(model.gatekeeper.lockoutSecondsRemaining) seconds.")
            } else {
                Button("Show Pairing Code") { model.openPairingCode() }
                    .disabled(!model.advertiser.isAdvertising)
                Text("Shows an eight-digit code for another device to enter.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
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

    @ViewBuilder
    private func statusBar(_ model: SyncModel) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            switch model.phase {
            case .idle, .awaitingApproval:
                EmptyView()

            case .preparing(let fraction):
                ProgressView(value: fraction)
                    .frame(maxWidth: 200)
                // Hashing a large library takes minutes on a first run, so say
                // what is happening rather than showing a bare spinner.
                Text("Checking your library…")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Cancel") { model.cancelRun() }

            case .transferring(let progress):
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 200)
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
                Button("Cancel") { model.cancelRun() }

            case .finished(let summary):
                Text(summaryText(summary))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()

            case .failed(let message):
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                Spacer()
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
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
                .foregroundStyle(Theme.textTertiary)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

/// `DiscoveredPeer` is already `Identifiable`; this makes it usable directly
/// as a `sheet(item:)` source.
extension DiscoveredPeer {}
