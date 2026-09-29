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
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<SyncSelection?, Never>?

    init(library: LibraryStore, playlistStore: PlaylistStore) {
        self.library = library
        self.playlistStore = playlistStore
        self.pairedPeers = peerStore.peers()
        // However the code goes away — expiry, Stop, success, failure — the
        // listener stops accepting the pairing key and stops advertising that
        // a code is showing.
        gatekeeper.onClose = { [weak self] in self?.advertiser.isPairingOpen = false }
    }

    // MARK: - Lifecycle

    /// Number of live users (the Sync window, Settings ▸ Devices). Networking
    /// runs while at least one is on screen.
    @ObservationIgnored private var activeUsers = 0

    /// Paired keys, read from the Keychain once per launch.
    ///
    /// On an ad-hoc-signed build every Keychain read can raise the macOS
    /// "wants to use your confidential information" prompt — the item's ACL
    /// names the exact binary that wrote it, and each rebuild is a new one.
    /// Reading on every window open and every sync meant a prompt each time;
    /// reading once and keeping the result current here means at most one per
    /// device per launch. The keys already live in memory on the listener, so
    /// this holds nothing that was not already resident.
    @ObservationIgnored private var keyCache: [UUID: SymmetricKey]?

    /// Called when the Sync window or Devices tab appears.
    func begin() {
        activeUsers += 1
        guard activeUsers == 1 else { return }
        browser.start()
        advertiser.pairedKeys = loadPairedKeys()
        advertiser.onConnection = { [weak self] connection in
            self?.handleIncoming(connection)
        }
        advertiser.start()
    }

    /// Called when the Sync window or Devices tab goes away. When the last user
    /// leaves everything stops — no listener, no browser, no pairing window.
    func end() {
        activeUsers = max(0, activeUsers - 1)
        guard activeUsers == 0 else { return }
        runTask?.cancel()
        runTask = nil
        resolveApproval(nil)
        // Stop first, so withdrawing the code below does not rebuild a
        // listener that is about to be torn down.
        advertiser.stop()
        gatekeeper.closePairing()
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
        keepListening()
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
    }

    /// Types a code into another device that is showing one.
    func pair(with peer: DiscoveredPeer, code: String) {
        keepListening()
        guard let endpoint = browser.endpoint(for: peer.deviceID) else {
            errorMessage = "That device is no longer on the network."
            return
        }
        pairingPeerID = peer.deviceID
        runTask = Task { [weak self] in
            guard let self else { return }
            defer { self.pairingPeerID = nil }
            do {
                _ = try await PairingExchange.runGuest(
                    endpoint: endpoint, code: code, identity: Self.localIdentity,
                    persist: { peer, key in try await self.savePairing(peer: peer, key: key) },
                    rollback: { deviceID in await self.forget(deviceID: deviceID) }
                )
            } catch let error as PairingError {
                self.errorMessage = error.userFacingMessage
            } catch {
                self.errorMessage = "Pairing failed. \(error)"
            }
        }
    }

    /// Saves a completed pairing. Throws rather than falling back to
    /// plaintext storage; `PairingExchange` then makes sure the other device
    /// does not keep its half either.
    private func savePairing(peer: PairedPeer, key: SymmetricKey) throws {
        do {
            try PeerKeyStore.store(key: key, for: peer.deviceID)
        } catch {
            print("[SyncModel] Couldn't save pairing key: \(error)")
            throw error
        }
        peerStore.upsert(peer)
        pairedPeers = peerStore.peers()
        var keys = loadPairedKeys()
        keys[peer.deviceID] = key
        keyCache = keys
        advertiser.pairedKeys = keys
    }

    /// Revokes a device. Deleting the key removes it from the listener's PSK
    /// set, so the peer cannot complete a handshake at all afterwards.
    func forget(deviceID: UUID) {
        try? PeerKeyStore.delete(deviceID: deviceID)
        peerStore.remove(deviceID: deviceID)
        pairedPeers = peerStore.peers()
        var keys = loadPairedKeys()
        keys[deviceID] = nil
        keyCache = keys
        advertiser.pairedKeys = keys
    }

    // MARK: - Syncing

    func sync(with peer: PeerRow) {
        keepListening()
        guard let endpoint = browser.endpoint(for: peer.peer.deviceID) else {
            errorMessage = "That device is no longer on the network."
            return
        }
        guard peer.peer.isCompatible else {
            errorMessage = "\(peer.displayName) is running a different version of "
                         + "FLACtastic's sync. Update both devices."
            return
        }
        guard let key = loadPairedKeys()[peer.peer.deviceID] else {
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
                try await SyncSession.connect(connection, peerName: peer.displayName)

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
                    pairedKey: key,
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
        resolveApproval(nil)
    }

    // MARK: - Approval

    /// Suspends the run until the user answers the confirmation sheet. Returns
    /// what they ticked, or `nil` if they cancelled.
    private func requestApproval(for plan: SyncPlan) async -> SyncSelection? {
        // Nothing to warn about and nothing to do — don't make the user
        // dismiss a sheet that says "no changes".
        if plan.isEmpty { return .everything }
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            phase = .awaitingApproval(plan)
        }
    }

    func approvePlan(_ selection: SyncSelection = .everything) {
        // Leave `.awaitingApproval` now so the sheet closes on the click,
        // rather than lingering until the first file reports progress.
        phase = .transferring(SyncSession.Progress())
        resolveApproval(selection)
    }
    func declinePlan() { resolveApproval(nil) }

    private func resolveApproval(_ selection: SyncSelection?) {
        guard let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        continuation.resume(returning: selection)
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
        // Snapshotted on arrival: the code that was on screen when the guest
        // connected, and the keys the listener accepted it under.
        let code = gatekeeper.currentCode()
        let keys = advertiser.pairedKeys

        Task { [weak self] in
            guard let self else { return }
            let connection = SyncConnection(accepted: raw)
            defer { Task { await connection.cancel() } }
            do {
                switch try await IncomingRequest.read(from: connection) {
                case .pairing(let hello):
                    try await self.hostPairing(connection: connection, hello: hello, code: code)
                case .sync(let hello):
                    try await self.respond(connection: connection, hello: hello, keys: keys)
                }
            } catch {
                print("[SyncModel] Incoming connection ended: \(error)")
            }
        }
    }

    private func hostPairing(connection: SyncConnection, hello: WireMessage.Hello, code: String?) async throws {
        do {
            _ = try await PairingExchange.runHost(
                on: connection, opening: hello, code: code, identity: Self.localIdentity,
                persist: { peer, key in try await self.savePairing(peer: peer, key: key) }
            )
            gatekeeper.recordSuccess()
        } catch PairingError.notAcceptingPairing {
            // No code was showing, so there was nothing to guess.
            throw PairingError.notAcceptingPairing
        } catch {
            if case PairingError.storageFailed = error {
                errorMessage = PairingError.storageFailed.userFacingMessage
            }
            // Every other failure burns the code, whatever caused it.
            gatekeeper.recordFailure()
            throw error
        }
    }

    private func respond(connection: SyncConnection, hello: WireMessage.Hello, keys: [UUID: SymmetricKey]) async throws {
        // Read on the main actor now; `prepare` runs later, off it.
        let root = library.rootURL
        let tracks = library.tracks
        let playlists = playlistStore.playlists
        let identity = Self.localIdentity

        let session = SyncSession()
        _ = try await session.runResponder(
            connection: connection,
            replaying: .hello(hello),
            identity: identity,
            authenticate: { keys[$0] },
            prepare: {
                // Only reached once the peer has proven it is paired, so an
                // unpaired device never learns whether a folder is open.
                guard let root else { throw ManifestBuilder.BuildError.noLibraryRoot }
                let manifest = try await ManifestBuilder().build(
                    tracks: tracks, playlists: playlists, rootURL: root,
                    deviceID: identity.deviceID, filter: .unrestricted
                )
                return SyncSession.LocalContext(
                    deviceID: identity.deviceID,
                    displayName: identity.displayName,
                    kind: identity.kind,
                    libraryRoot: root,
                    manifest: manifest,
                    filter: .unrestricted,
                    playlists: playlists
                )
            }
        )
        if let root { await absorb(landed: await session.landed, root: root) }
    }

    // MARK: - Helpers

    private static var localIdentity: PairingIdentity {
        PairingIdentity(
            deviceID: DeviceIdentity.deviceID,
            displayName: DeviceIdentity.displayName,
            kind: DeviceIdentity.kind
        )
    }

    /// Resets the listener's idle timer on user activity — or restarts it if
    /// the timer already fired with the window open.
    private func keepListening() {
        guard activeUsers > 0 else { return }
        advertiser.keepAlive()
    }

    private func loadPairedKeys() -> [UUID: SymmetricKey] {
        if let keyCache { return keyCache }
        var keys: [UUID: SymmetricKey] = [:]
        for peer in pairedPeers {
            if let key = (try? PeerKeyStore.key(for: peer.deviceID)) ?? nil {
                keys[peer.deviceID] = key
            }
        }
        keyCache = keys
        return keys
    }
}

private extension SyncSession.SessionError {
    var isCancellation: Bool {
        if case .declined = self { return true }
        return false
    }
}
