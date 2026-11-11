import Foundation
import Network
import Observation
import os

/// A server seen on the network. Every field was written by whoever is on the
/// network; nothing here is trusted until the user confirms the fingerprint.
struct DiscoveredServer: Identifiable, Hashable {
    let id: UUID
    let name: String
    let version: String
    fileprivate let endpoint: NWEndpoint

    var isCompatible: Bool { version.split(separator: ".").first == "2" }
}

/// Browses `_flactastic-srv._tcp` (§2) and resolves a pick to host:port.
@Observable
@MainActor
final class ServerDiscovery {
    static let serviceType = "_flactastic-srv._tcp"

    private(set) var servers: [DiscoveredServer] = []
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: "local."), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results) }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { print("[ServerDiscovery] \(error)") }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        servers = []
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        var found: [UUID: DiscoveredServer] = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  let server = Self.decode(txt.dictionary, endpoint: result.endpoint) else { continue }
            found[server.id] = server
        }
        servers = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// TXT keys `v`, `id` and `n`; the name is cleaned as v1 cleans peer names.
    fileprivate static func decode(_ txt: [String: String], endpoint: NWEndpoint) -> DiscoveredServer? {
        guard let id = txt["id"].flatMap(UUID.init(uuidString:)), let version = txt["v"] else { return nil }
        let name = TXTRecordCodec.sanitizeDisplayName(txt["n"], fallback: "FLACtastic Server")
        return DiscoveredServer(id: id, name: name, version: version, endpoint: endpoint)
    }

    /// The address behind a discovered service, preferring IPv4 so the URL
    /// needs no zone ID.
    static func resolve(_ server: DiscoveredServer) async -> ServerAddress? {
        for v4 in [true, false] {
            if let address = await resolve(server.endpoint, ipv4Only: v4) { return address }
        }
        return nil
    }

    private static func resolve(_ endpoint: NWEndpoint, ipv4Only: Bool) async -> ServerAddress? {
        let parameters = NWParameters.tcp
        if ipv4Only, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        return await withCheckedContinuation { (continuation: CheckedContinuation<ServerAddress?, Never>) in
            let done = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (ServerAddress?) -> Void = { address in
                guard done.withLock({ let was = $0; $0 = true; return !was }) else { return }
                connection.cancel()
                continuation.resume(returning: address)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                        let text: String
                        switch host {
                        case .ipv4(let a): text = "\(a)"
                        case .ipv6(let a): text = "\(a)"
                        case .name(let n, _): text = n
                        @unknown default: text = "\(host)"
                        }
                        finish(ServerAddress(host: text, port: Int(port.rawValue)))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }
}
