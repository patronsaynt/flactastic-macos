import Foundation
import Network
import Observation

/// Finds other FLACtastic instances on the local network.
///
/// Browsing is passive and reveals nothing about this device — it is safe to
/// run whenever the Sync screen is open, unlike advertising. The results are
/// unauthenticated: every field in `DiscoveredPeer` was written by whoever is
/// on the network, and a device may be lying about all of it. Nothing here
/// grants any trust; that only comes from a completed pairing.
@Observable
@MainActor
final class PeerBrowser {

    // MARK: - State

    private(set) var peers: [DiscoveredPeer] = []
    private(set) var isBrowsing = false
    private(set) var failureMessage: String?

    @ObservationIgnored private var browser: NWBrowser?
    /// Endpoints kept alongside the peers, because `NWEndpoint` is what a
    /// connection actually needs and it is not `Hashable` in a way worth
    /// putting in the UI-facing model.
    @ObservationIgnored private var endpointsByDeviceID: [UUID: NWEndpoint] = [:]

    // MARK: - Lifecycle

    func start() {
        guard browser == nil else { return }
        failureMessage = nil

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: SyncProtocol.bonjourServiceType,
            domain: SyncProtocol.bonjourDomain
        )
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.failureMessage = nil
                case .failed(let error):
                    self?.failureMessage = PeerAdvertiser.userFacingMessage(for: error)
                    print("[PeerBrowser] Browser failed: \(error)")
                    self?.stop()
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results: results) }
        }

        browser.start(queue: .main)
        self.browser = browser
        isBrowsing = true
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        peers = []
        endpointsByDeviceID = [:]
    }

    /// The endpoint to dial for a discovered peer, or `nil` if it has gone
    /// away since the list was rendered.
    func endpoint(for deviceID: UUID) -> NWEndpoint? {
        endpointsByDeviceID[deviceID]
    }

    // MARK: - Results

    /// Flattens `NWTXTRecord` into plain strings.
    ///
    /// A TXT entry can be a string, raw bytes, present-but-empty, or absent.
    /// Only the string case carries anything we advertise, but a peer can send
    /// any of them — the `.data` case is decoded as UTF-8 when it is valid and
    /// dropped when it is not, rather than being coerced into replacement
    /// characters that would then be shown to the user as a device name.
    private static func stringEntries(from record: NWTXTRecord) -> [String: String] {
        var entries: [String: String] = [:]
        for entry in record {
            switch entry.value {
            case .string(let value):
                entries[entry.key] = value
            case .data(let data):
                if let value = String(data: data, encoding: .utf8) { entries[entry.key] = value }
            case .empty, .none:
                continue
            @unknown default:
                continue
            }
        }
        return entries
    }

    private func apply(results: Set<NWBrowser.Result>) {
        var found: [DiscoveredPeer] = []
        var endpoints: [UUID: NWEndpoint] = [:]

        for result in results {
            guard case .bonjour(let txtRecord) = result.metadata else { continue }
            guard let peer = TXTRecordCodec.decode(
                Self.stringEntries(from: txtRecord),
                endpointDescription: String(describing: result.endpoint)
            ) else { continue }

            // Ignore our own advertisement. Without this the user sees their
            // own Mac in the list and can try to sync a library with itself.
            guard peer.deviceID != DeviceIdentity.deviceID else { continue }

            // Two devices claiming the same ID is either a cloned install or
            // someone spoofing a paired peer's identifier. Neither is safe to
            // silently pick a winner for, so drop both and say so.
            if endpoints[peer.deviceID] != nil {
                print("[PeerBrowser] Duplicate device ID \(peer.deviceID) on the network; ignoring both.")
                endpoints.removeValue(forKey: peer.deviceID)
                found.removeAll { $0.deviceID == peer.deviceID }
                continue
            }

            found.append(peer)
            endpoints[peer.deviceID] = result.endpoint
        }

        // Sort for a stable list: compatible peers first, then by name. A row
        // that reorders itself while the user is reaching for it is worse than
        // one that is slightly stale.
        peers = found.sorted {
            if $0.isCompatible != $1.isCompatible { return $0.isCompatible }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        endpointsByDeviceID = endpoints
    }
}
