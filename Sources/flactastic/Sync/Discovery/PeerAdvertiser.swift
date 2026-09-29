import Foundation
import Network
import Observation
import CryptoKit

/// Advertises this device on the local network so peers can find it.
///
/// **Off by default, and deliberately hard to leave on.** Advertising tells
/// every device on the network that this Mac is running FLACtastic and is
/// willing to accept a connection, so it starts only when the user opens the
/// Sync screen, stops when they leave it, and stops again on an idle timer if
/// they walk away with the window open. A music player has no business holding
/// an open listener on a café Wi-Fi indefinitely.
///
/// The listener accepts TCP connections but does **not** decide what to do with
/// them — `onConnection` hands each one to the transport layer, which refuses
/// anything that is neither a paired peer nor an in-progress pairing.
@Observable
@MainActor
final class PeerAdvertiser {

    // MARK: - State

    private(set) var isAdvertising = false
    /// Set when the listener fails. Surfaced in the UI, because the most common
    /// cause on iOS and modern macOS is the user having denied the local
    /// network permission — which is otherwise completely silent.
    private(set) var failureMessage: String?
    /// The port actually bound. Assigned by the OS; exposed for tests.
    private(set) var boundPort: UInt16?

    /// Whether a pairing code is currently on screen.
    ///
    /// Changing it does more than update the TXT record: the pairing PSK is
    /// only registered on the listener while this is true, so closing the
    /// pairing window actually removes the ability to connect without a key,
    /// rather than merely advertising that it is closed. That requires
    /// rebuilding the listener, which is why this restarts it.
    var isPairingOpen = false {
        didSet {
            guard isPairingOpen != oldValue, isAdvertising else { return }
            restartListener()
        }
    }

    /// Keys for every currently paired peer. Set by the sync service from
    /// `PeerKeyStore`; the listener registers one PSK per entry, so a peer that
    /// is not in this map cannot complete a handshake at all.
    var pairedKeys: [UUID: SymmetricKey] = [:] {
        didSet {
            // Compare the key material, not just the device IDs. Re-pairing a
            // device keeps its ID and replaces its key; comparing IDs alone
            // left the listener holding the old key, so the re-paired device
            // could be dialled but could never dial in.
            guard isAdvertising, Self.material(oldValue) != Self.material(pairedKeys) else { return }
            restartListener()
        }
    }

    private static func material(_ keys: [UUID: SymmetricKey]) -> [UUID: Data] {
        keys.mapValues { $0.withUnsafeBytes { Data($0) } }
    }

    /// Called for each accepted connection. The advertiser itself performs no
    /// authentication — that is the transport's job.
    @ObservationIgnored var onConnection: (@MainActor (NWConnection) -> Void)?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var idleTimer: Task<Void, Never>?

    /// How long the listener stays up without the Sync screen refreshing it.
    @ObservationIgnored private let idleTimeout: Duration = .seconds(600)

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else {
            restartIdleTimer()
            return
        }
        failureMessage = nil

        do {
            // Every connection is TLS-PSK authenticated. A peer whose key is
            // absent from `pairedKeys` fails the handshake, so revocation needs
            // no application-level check to enforce it.
            let parameters = SyncTLS.listenerParameters(
                pairedKeys: pairedKeys,
                allowPairing: isPairingOpen
            )

            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                type: SyncProtocol.bonjourServiceType,
                domain: SyncProtocol.bonjourDomain,
                txtRecord: NWTXTRecord(currentTXTEntries()).data
            )

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handle(state: state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.onConnection?(connection) }
            }

            listener.start(queue: .main)
            self.listener = listener
            isAdvertising = true
            restartIdleTimer()
        } catch {
            failureMessage = "Couldn't start the sync listener: \(error.localizedDescription)"
            print("[PeerAdvertiser] Failed to start: \(error)")
        }
    }

    func stop() {
        idleTimer?.cancel()
        idleTimer = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
        isAdvertising = false
    }

    /// Called on every user action on the Sync screen (sync, pair, show a
    /// code). Resets the idle timer — and, if it already fired while the
    /// screen sat open, brings the listener back, so walking away and coming
    /// back to the same window never leaves this device silently unreachable.
    func keepAlive() {
        start()
    }

    // MARK: - Internals

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            boundPort = listener?.port?.rawValue
            failureMessage = nil
        case .failed(let error):
            // On macOS 15+ and iOS 14+ a denied local-network permission
            // surfaces here rather than at start(), and with a message that
            // means nothing to a user. Say what to actually do about it.
            failureMessage = Self.userFacingMessage(for: error)
            print("[PeerAdvertiser] Listener failed: \(error)")
            stop()
        case .cancelled:
            isAdvertising = false
        default:
            break
        }
    }

    private func currentTXTEntries() -> [String: String] {
        TXTRecordCodec.encode(
            deviceID: DeviceIdentity.deviceID,
            displayName: DeviceIdentity.displayName,
            kind: DeviceIdentity.kind,
            isPairingOpen: isPairingOpen
        )
    }

    /// Rebuilds the listener so a changed PSK set takes effect.
    ///
    /// The set of pre-shared keys is fixed when `NWListener` is created, so
    /// there is no way to add or revoke one in place. Tearing down and
    /// restarting is momentarily disruptive — any in-flight sync on this
    /// listener drops — which is why callers only change `pairedKeys` and
    /// `isPairingOpen` between runs, never during one.
    private func restartListener() {
        guard isAdvertising else { return }
        listener?.cancel()
        listener = nil
        boundPort = nil
        isAdvertising = false
        start()
    }

    private func restartIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task { [idleTimeout] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            self.stop()
        }
    }

    static func userFacingMessage(for error: NWError) -> String {
        switch error {
        case .posix(.EPERM), .posix(.EACCES):
            return "FLACtastic isn't allowed to use the local network. "
                 + "Grant access in System Settings → Privacy & Security → Local Network."
        case .posix(.EADDRINUSE):
            return "Another copy of FLACtastic is already listening for syncs on this Mac."
        default:
            return "Couldn't advertise on the network: \(error.localizedDescription)"
        }
    }
}
