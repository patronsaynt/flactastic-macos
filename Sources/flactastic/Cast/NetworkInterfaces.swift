import Darwin
import Foundation

/// IPv4 interface enumeration, used to multicast SSDP searches on every LAN
/// interface and to pick the address a renderer can reach us on.
enum NetworkInterfaces {

    struct IPv4Interface: Equatable, Sendable {
        let name: String
        let address: in_addr_t   // network byte order
        let netmask: in_addr_t   // network byte order

        var addressString: String { NetworkInterfaces.string(from: address) }
    }

    /// Up, running, non-loopback IPv4 interfaces.
    static func ipv4Interfaces() -> [IPv4Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [IPv4Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            let address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            result.append(IPv4Interface(name: String(cString: entry.ifa_name), address: address, netmask: netmask))
        }
        return result
    }

    /// Our address on the subnet shared with `host` (a dotted IPv4 literal).
    /// Falls back to the first Ethernet/Wi-Fi interface when no subnet matches,
    /// e.g. the renderer is reached through a router.
    static func localAddress(toward host: String, in interfaces: [IPv4Interface] = ipv4Interfaces()) -> String? {
        if let target = parse(host),
           let match = interfaces.first(where: { ($0.address & $0.netmask) == (target & $0.netmask) }) {
            return match.addressString
        }
        return (interfaces.first { $0.name.hasPrefix("en") } ?? interfaces.first)?.addressString
    }

    static func parse(_ dotted: String) -> in_addr_t? {
        var addr = in_addr()
        return inet_pton(AF_INET, dotted, &addr) == 1 ? addr.s_addr : nil
    }

    static func string(from address: in_addr_t) -> String {
        var addr = in_addr(s_addr: address)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}
