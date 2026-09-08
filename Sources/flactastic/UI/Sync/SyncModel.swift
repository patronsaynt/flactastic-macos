import Foundation
import Network
import Observation
import CryptoKit

/// Drives the Sync window: discovery, pairing, and running a sync.
///
/// `@Observable @MainActor`, like every other store in the app, with all the
/// actual I/O delegated to the actors underneath (`ManifestBuilder`,
/// `SyncSession`, `SyncConnection`). Nothing here blocks the main thread; what
/// it owns is the state the window renders and the decisions the user makes.
///
/// Deliberately **not** created at app launch. It is built when the Sync window
/// opens and torn down when it closes, so a user who never syncs never
/// advertises on the network, never opens a listener, and never reads a byte of
/// their library for hashing.
@Observable
@MainActor
final class SyncModel {

    // MARK: - Types

    enum Phase: Equatable {
        case idle
        /// Building this device's manifest — the slow, hashing part.
        case preparing(fraction: Double)
        case awaitingApproval(SyncPlan)
        case transferring(SyncSession.Progress)
        case finished(SyncSession.Summary)
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.preparing(let a), .preparing(let b)): return a == b
            case (.awaitingApproval(let a), .awaitingApproval(let b)): return a.planHash == b.planHash
            case (.transferring(let a), .transferring(let b)): return a.fraction == b.fraction
            case (.finished(let a), .finished(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    // MARK: - State

    let advertiser = PeerAdvertiser()
    let browser = PeerBrowser()
    let gatekeeper = PairingGatekeeper()

    private(set) var pairedPeers: [PairedPeer] = []
    private(set) var phase: Phase = .idle
    /// The peer a run is currently against, if any.
    private(set) var activePeerID: UUID?
    /// Set when pairing is in progress with a discovered peer.
    private(set) var pairingPeerID: UUID?
    var errorMessage: String?

    /// The user's choice for the next run. Direction is per-run by design —
    /// bi-directional convergence is two runs, which keeps the "what is about
    /// to happen to my files" question answerable in one sentence.
    var direction: SyncDirection = .push

    private let library: LibraryStore
    private let playlistStore: PlaylistStore
    private let peerStore = SyncPeerStore()

    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Resolved when the user answers the confirmation sheet.
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?

    init(library: LibraryStore, playlistStore: PlaylistStore) {
        self.library = library
        self.playlistStore = playlistStore
        self.pairedPeers = peerStore.peers()
    }

    // MARK: - Lifecycle

    /// Called when the Sync window appears.
    func begin() {
        browser.start()
        advertiser.pairedKeys = loadPairedKeys()
        advertiser.onConnection = { [weak self] connection in
            self?.handleIncoming(connection)
        }
        advertiser.start()
    }

    /// Called when the Sync window closes. Everything stops — no listener, no
    /// browser, no pairing window survives the window being shut.
    func end() {
        runTask?.cancel()
        runTask = nil
        resolveApproval(false)
        gatekeeper.closePairing()
        advertiser.stop()
        browser.stop()
        phase = .idle
        activePeerID = nil
    }

    // MARK: - Peer list

    /// Discovered peers, annotated with whether they are already paired.
    struct PeerRow: Identifiable {
        let peer: DiscoveredPeer
        let paired: PairedPeer?
        var id: UUID { peer.deviceID }
        var isPaired: Bool { paired != nil }
        /// Prefer the name recorded at pairing time. A paired device's name is
        /// one we authenticated; the advertised one is attacker-controlled
        /// text that anyone on the network can set.
        var displayName: String { paired?.displayName ?? peer.displayName }
        var lastSyncedAt: Date? { paired?.lastSyncedAt }
    }

    var rows: [PeerRow] {
        let pairedByID = Dictionary(pairedPeers.map { ($0.deviceID, $0) }, uniquingKeysWith: { a, _ in a })
        return browser.peers.map { PeerRow(peer: $0, paired: pairedByID[$0.deviceID]) }
    }

    /// Peers we have paired with but cannot currently see. Shown so "forget"
    /// remains reachable for a device that is switched off.
    var offlinePairedPeers: [PairedPeer] {
        let visible = Set(browser.peers.map(\.deviceID))
        return pairedPeers.filter { !visible.contains($0.deviceID) }
    }

    // MARK: - Pairing

    /// Shows a code on this device for another to type in.
    func openPairingCode() {
        guard let code = gatekeeper.openPairing() else {
            errorMessage = "Too many failed attempts. Try again in "
                         + "\(gatekeeper.lockoutSecondsRemaining) seconds."
            return
        }
        _ = code
        advertiser.isPairingOpen = true
    }

    func closePairingCode() {
        gatekeeper.closePairing()
        advertiser.isPairingOpen = false
    }

    /// Types a code into another device that is showing one.
    func pair(with peer: DiscoveredPeer, code: String) {
        guard let endpoint = browser.endpoint(for: peer.deviceID) else {
            errorMessage = "That device is no longer on the network."
            return
        }
        pairingPeerID = peer.deviceID
        runTask = Task { [weak self] in
            guard let self else { return }
            defer { self.pairingPeerID = nil }
            do {
                let identity = PairingIdentity(
                    deviceID: DeviceIdentity.deviceID,
                    displayName: DeviceIdentity.displayName,
                    kind: DeviceIdentity.kind
                )
                let session = try GuestPairingSession(typedCode: code, identity: identity)
                let connection = SyncConnection(pairingWith: endpoint)
                defer { Task { await connection.cancel() } }
                try await connection.start()

                while true {
                    let message = try await connection.receiveMessage(timeout: .seconds(60))
                    switch try session.receive(message) {
                    case .send(let next):
                        try await connection.send(next)
                    case .sendAndFinish(let next, let peer, let key):
                        try await connection.send(next)
                        self.completePairing(peer: peer, key: key)
                        return
                    case .finish(let peer, let key):
                        self.completePairing(peer: peer, key: key)
                        return
                    }
                }
            } catch let error as PairingError {
                self.errorMessage = error.userFacingMessage
            } catch {
                self.errorMessage = "Pairing failed. \(error)"
            }
        }
    }

    private func completePairing(peer: PairedPeer, key: SymmetricKey) {
        do {
            try PeerKeyStore.store(key: key, for: peer.deviceID)
        } catch {
            // Refusing to fall back to plaintext storage means this is fatal,
            // and the user needs to know rather than believing they are paired.
            errorMessage = "Couldn't save the pairing securely: \(error)"
            return
        }
        peerStore.upsert(peer)
        pairedPeers = peerStore.peers()
        advertiser.pairedKeys = loadPairedKeys()
        gatekeeper.recordSuccess()
        advertiser.isPairingOpen = false
    }

    /// Revokes a device. Deleting the key removes it from the listener's PSK
    /// set, so the peer cannot complete a handshake at all afterwards.
    func forget(deviceID: UUID) {
        try? PeerKeyStore.delete(deviceID: deviceID)
        peerStore.remove(deviceID: deviceID)
        pairedPeers = peerStore.peers()
        advertiser.pairedKeys = loadPairedKeys()
    }

    // MARK: - Syncing

    func sync(with peer: PeerRow) {
        guard let endpoint = browser.endpoint(for: peer.peer.deviceID) else {
            errorMessage = "That device is no longer on the network."
            return
        }
        guard peer.peer.isCompatible else {
            errorMessage = "\(peer.displayName) is running a different version of "
                         + "FLACtastic's sync. Update both devices."
            return
        }
        guard let key = (try? PeerKeyStore.key(for: peer.peer.deviceID)) ?? nil else {
            errorMessage = "\(peer.displayName) isn't paired with this Mac yet."
            return
        }
        guard let root = library.rootURL else {
            errorMessage = "Open a music folder before syncing."
            return
        }

        activePeerID = peer.peer.deviceID
        let deviceID = peer.peer.deviceID
        let filter = peerStore.filter(for: deviceID)
        let direction = self.direction
        let tracks = library.tracks
        let playlists = playlistStore.playlists

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.phase = .preparing(fraction: 0)
                let manifest = try await ManifestBuilder().build(
                    tracks: tracks, playlists: playlists, rootURL: root,
                    deviceID: DeviceIdentity.deviceID, filter: filter,
                    progress: { fraction in
                        Task { @MainActor in self.phase = .preparing(fraction: fraction) }
                    }
                )

                let connection = SyncConnection(
                    endpoint: endpoint, key: key, localDeviceID: DeviceIdentity.deviceID
                )
                defer { Task { await connection.cancel() } }
                try await connection.start()

                let context = SyncSession.LocalContext(
                    deviceID: DeviceIdentity.deviceID,
                    displayName: DeviceIdentity.displayName,
                    kind: DeviceIdentity.kind,
                    libraryRoot: root,
                    manifest: manifest,
                    filter: filter,
                    playlists: playlists
                )
                let session = SyncSession()
                let summary = try await session.runInitiator(
                    connection: connection,
                    direction: direction,
                    local: context,
                    approve: { plan in await self.requestApproval(for: plan) },
                    progress: { progress in
                        Task { @MainActor in self.phase = .transferring(progress) }
                    }
                )

                if direction == .pull {
                    await self.absorb(landed: await session.landed, root: root)
                }
                self.peerStore.recordSync(deviceID: deviceID, at: .now)
                self.pairedPeers = self.peerStore.peers()
                self.phase = .finished(summary)
            } catch is CancellationError {
                self.phase = .idle
            } catch let error as SyncSession.SessionError {
                self.phase = error.isCancellation ? .idle : .failed(error.description)
            } catch {
                self.phase = .failed("\(error)")
            }
            self.activePeerID = nil
        }
    }

    func cancelRun() {
        runTask?.cancel()
        resolveApproval(false)
    }

    // MARK: - Approval

    /// Suspends the run until the user answers the confirmation sheet.
    private func requestApproval(for plan: SyncPlan) async -> Bool {
        // Nothing to warn about and nothing to do — don't make the user
        // dismiss a sheet that says "no changes".
        if plan.isEmpty { return true }
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            phase = .awaitingApproval(plan)
        }
    }

    func approvePlan() { resolveApproval(true) }
    func declinePlan() { resolveApproval(false) }

    private func resolveApproval(_ approved: Bool) {
        guard let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        continuation.resume(returning: approved)
    }

    // MARK: - Applying a pull

    /// Folds files and playlists received by a pull into this device's stores.
    ///
    /// Adopting the sender's track IDs is what makes the *next* sync cheap: the
    /// two libraries then agree on identity and match without re-hashing.
    private func absorb(landed: SyncSession.Landed, root: URL) async {
        let idStore = TrackIDStore()
        idStore.load(from: root)
        for file in landed.files {
            let relativePath = TrackMetadataCache.relativePath(for: file.destination, rootPath: root.path)
            idStore.adopt(file.trackID, for: file.destination, relativePath: relativePath)
        }
        idStore.save()

        for playlist in landed.playlists {
            playlistStore.upsertFromSync(playlist)
        }

        // New files on disk mean the library has to be rescanned before they
        // appear anywhere in the UI.
        library.refreshLibrary()
    }

    // MARK: - Incoming connections

    /// Handles a peer that dialled us. Runs unattended: the responder makes no
    /// decisions of its own beyond enforcing its own filters and limits.
    private func handleIncoming(_ raw: NWConnection) {
        guard let root = library.rootURL else { return }
        let tracks = library.tracks
        let playlists = playlistStore.playlists
        let code = gatekeeper.currentCode()

        Task { [weak self] in
            guard let self else { return }
            let connection = SyncConnection(accepted: raw)
            defer { Task { await connection.cancel() } }
            do {
                try await connection.start()
                let first = try await connection.receiveMessage(timeout: .seconds(30))

                if case .pairCommit = first {
                    // Should never happen: the host sends the commit. A guest
                    // opening with one is malformed.
                    return
                }
                if case .pairGuestKey = first {
                    try await self.runPairingHost(connection: connection, firstMessage: first, code: code)
                    return
                }
                guard case .hello = first else { return }
                try await self.runResponder(
                    connection: connection, firstMessage: first,
                    root: root, tracks: tracks, playlists: playlists
                )
            } catch {
                print("[SyncModel] Incoming connection ended: \(error)")
            }
        }
    }

    private func runPairingHost(
        connection: SyncConnection,
        firstMessage: WireMessage,
        code: String?
    ) async throws {
        guard let code else {
            try await connection.send(.protocolError(.init(
                code: .pairingClosed, message: "Not pairing."
            )))
            return
        }
        let session = HostPairingSession(code: code, identity: PairingIdentity(
            deviceID: DeviceIdentity.deviceID,
            displayName: DeviceIdentity.displayName,
            kind: DeviceIdentity.kind
        ))
        // The commit must already have been sent for the guest to have replied
        // with a key, so replay it into the session's state machine.
        _ = session.begin()

        var message = firstMessage
        while true {
            do {
                switch try session.receive(message) {
                case .send(let next):
                    try await connection.send(next)
                case .sendAndFinish(let next, let peer, let key):
                    try await connection.send(next)
                    completePairing(peer: peer, key: key)
                    return
                case .finish(let peer, let key):
                    completePairing(peer: peer, key: key)
                    return
                }
            } catch {
                // Every failure burns the code, whatever caused it.
                gatekeeper.recordFailure()
                advertiser.isPairingOpen = false
                try? await connection.send(.pairResult(.init(
                    success: false, failureReason: "Pairing failed."
                )))
                throw error
            }
            message = try await connection.receiveMessage(timeout: .seconds(60))
        }
    }

    private func runResponder(
        connection: SyncConnection,
        firstMessage: WireMessage,
        root: URL,
        tracks: [Track],
        playlists: [Playlist]
    ) async throws {
        // The responder path in SyncSession expects to read `hello` itself, so
        // this replays what has already been consumed.
        let manifest = try await ManifestBuilder().build(
            tracks: tracks, playlists: playlists, rootURL: root,
            deviceID: DeviceIdentity.deviceID, filter: .unrestricted
        )
        let context = SyncSession.LocalContext(
            deviceID: DeviceIdentity.deviceID,
            displayName: DeviceIdentity.displayName,
            kind: DeviceIdentity.kind,
            libraryRoot: root,
            manifest: manifest,
            filter: .unrestricted,
            playlists: playlists
        )
        let session = SyncSession()
        _ = try await session.runResponder(
            connection: connection, local: context, replaying: firstMessage
        )
        await absorb(landed: await session.landed, root: root)
    }

    // MARK: - Helpers

    private func loadPairedKeys() -> [UUID: SymmetricKey] {
        var keys: [UUID: SymmetricKey] = [:]
        for peer in pairedPeers {
            if let key = (try? PeerKeyStore.key(for: peer.deviceID)) ?? nil {
                keys[peer.deviceID] = key
            }
        }
        return keys
    }
}

private extension SyncSession.SessionError {
    var isCancellation: Bool {
        if case .declined = self { return true }
        return false
    }
}
