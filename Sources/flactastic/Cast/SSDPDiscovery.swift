import Darwin
import Foundation

// MARK: - Message parsing

/// One SSDP datagram: an M-SEARCH response or a NOTIFY announcement.
struct SSDPMessage: Equatable, Sendable {
    let location: URL?
    let usn: String
    /// `ST` for search responses, `NT` for NOTIFY.
    let target: String?
    let maxAge: TimeInterval?
    let isByeBye: Bool

    static func parse(_ text: String) -> SSDPMessage? {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let start = lines.first?.uppercased(),
              start.hasPrefix("HTTP/1.1 200") || start.hasPrefix("NOTIFY ") else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        guard let usn = headers["usn"], !usn.isEmpty else { return nil }

        let isByeBye = headers["nts"]?.lowercased() == "ssdp:byebye"
        let location = headers["location"].flatMap(URL.init(string:))
        guard isByeBye || location != nil else { return nil }

        var maxAge: TimeInterval?
        if let cache = headers["cache-control"]?.lowercased(),
           let range = cache.range(of: "max-age") {
            let digits = cache[range.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber }
            maxAge = TimeInterval(digits)
        }
        return SSDPMessage(location: location, usn: usn, target: headers["st"] ?? headers["nt"],
                           maxAge: maxAge, isByeBye: isByeBye)
    }

    /// The device part of a USN (`uuid:…`), shared by all of its services.
    var deviceUDN: String {
        usn.components(separatedBy: "::").first ?? usn
    }
}

// MARK: - Socket

/// Sends SSDP M-SEARCH requests for media renderers on every IPv4 interface
/// and reports the unicast responses. A single UDP socket on an ephemeral port
/// is enough: responses come back to the sender's port, and periodic searches
/// replace listening for NOTIFY (which would need port 1900).
///
/// Socket state is confined to `queue`.
final class SSDPDiscovery: @unchecked Sendable {
    static let mediaRendererTarget = "urn:schemas-upnp-org:device:MediaRenderer:1"
    private static let multicastAddress = "239.255.255.250"
    private static let multicastPort: UInt16 = 1900

    private let queue = DispatchQueue(label: "flactastic.ssdp")
    private let onMessage: @Sendable (SSDPMessage) -> Void
    private let onSendResult: @Sendable (_ blocked: Bool) -> Void
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    /// `onSendResult` reports after each search burst whether macOS refused
    /// every send — what a denied Local Network permission looks like
    /// (EHOSTUNREACH / EPERM on multicast).
    init(onMessage: @escaping @Sendable (SSDPMessage) -> Void,
         onSendResult: @escaping @Sendable (_ blocked: Bool) -> Void = { _ in }) {
        self.onMessage = onMessage
        self.onSendResult = onSendResult
    }

    deinit {
        readSource?.cancel()
    }

    /// Send a search burst. Opens the socket on first use.
    func search() {
        queue.async { [self] in
            guard openSocketIfNeeded() else { return }
            sendSearch()
            // UDP over Wi-Fi drops packets; a second burst a moment later is
            // what most control points do too.
            queue.asyncAfter(deadline: .now() + 0.6) { [self] in sendSearch() }
        }
    }

    func stop() {
        queue.async { [self] in
            readSource?.cancel()
            readSource = nil
            socketFD = -1
        }
    }

    static func searchRequest(target: String = mediaRendererTarget, mx: Int = 2) -> String {
        "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: \(multicastAddress):\(multicastPort)\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: \(mx)\r\n"
            + "ST: \(target)\r\n"
            + "USER-AGENT: macOS UPnP/1.1 FLACtastic/1.0\r\n"
            + "\r\n"
    }

    private func openSocketIfNeeded() -> Bool {
        if readSource != nil { return true }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            print("[SSDP] socket() failed: \(errno)")
            return false
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var bindAddr = sockaddr_in()
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_addr.s_addr = INADDR_ANY
        bindAddr.sin_port = 0
        let bound = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            print("[SSDP] bind() failed: \(errno)")
            close(fd)
            return false
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(fd) }
        source.resume()
        socketFD = fd
        readSource = source
        return true
    }

    private func sendSearch() {
        guard socketFD >= 0 else { return }
        let payload = Array(Self.searchRequest().utf8)
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = Self.multicastPort.bigEndian
        dest.sin_addr.s_addr = NetworkInterfaces.parse(Self.multicastAddress) ?? 0

        let interfaces = NetworkInterfaces.ipv4Interfaces()
        var sent = 0
        var blocked = 0
        // Send once per interface so a Mac on both Ethernet and Wi-Fi finds
        // renderers on either; fall back to the routing table's default.
        let targets: [in_addr_t?] = interfaces.isEmpty ? [nil] : interfaces.map(\.address)
        for ifaceAddr in targets {
            if let ifaceAddr {
                var iface = in_addr(s_addr: ifaceAddr)
                setsockopt(socketFD, IPPROTO_IP, IP_MULTICAST_IF, &iface, socklen_t(MemoryLayout<in_addr>.size))
            }
            let result = withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result >= 0 {
                sent += 1
            } else {
                let code = errno
                if code == EHOSTUNREACH || code == EPERM || code == EACCES { blocked += 1 }
                castLog.error("SSDP send failed: errno \(code, privacy: .public) (\(String(cString: strerror(code)), privacy: .public))")
            }
        }
        onSendResult(sent == 0 && blocked > 0)
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(socketFD, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            let data = Data(buffer[0..<count])
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  let message = SSDPMessage.parse(text) else { continue }
            onMessage(message)
        }
    }
}
