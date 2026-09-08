import Foundation

/// Builds and parses the Bonjour TXT record.
///
/// Kept separate from `PeerAdvertiser`/`PeerBrowser` and free of any `Network`
/// import so the parsing half — the half that reads bytes a stranger wrote —
/// can be unit-tested exhaustively without standing up an mDNS responder.
///
/// **What may go in here:** enough for the user to recognise their own device
/// and for us to reject an incompatible protocol version before connecting.
/// **What may never go in here:** anything about the library, the user, or the
/// filesystem. A TXT record is broadcast unencrypted to every device on the
/// network, logged by many of them, and cached by some.
enum TXTRecordCodec {

    /// Bonjour TXT is a DNS record: values are short, and a key/value pair over
    /// 255 bytes is silently mangled by the resolver rather than rejected. Keep
    /// well inside that.
    static let maxValueBytes = 63

    static func encode(
        deviceID: UUID,
        displayName: String,
        kind: SyncDeviceKind,
        isPairingOpen: Bool,
        version: SyncProtocol.Version = SyncProtocol.version
    ) -> [String: String] {
        [
            SyncProtocol.TXTKey.protocolVersion: "\(version.major).\(version.minor)",
            SyncProtocol.TXTKey.deviceID: deviceID.uuidString,
            SyncProtocol.TXTKey.displayName: clamp(displayName),
            SyncProtocol.TXTKey.deviceKind: kind.rawValue,
            SyncProtocol.TXTKey.pairingOpen: isPairingOpen ? "1" : "0",
        ]
    }

    /// Parses a peer's record. Returns `nil` rather than throwing when the
    /// record is unusable: an unparseable advertisement on a shared network is
    /// ordinary noise — another app on the same service type, a stale cache
    /// entry, a device mid-shutdown — not an error worth surfacing.
    static func decode(_ entries: [String: String], endpointDescription: String) -> DiscoveredPeer? {
        guard let idString = entries[SyncProtocol.TXTKey.deviceID],
              let deviceID = UUID(uuidString: idString) else { return nil }
        guard let version = parseVersion(entries[SyncProtocol.TXTKey.protocolVersion]) else { return nil }

        // A missing or unrecognised kind is survivable — it only picks an icon.
        let kind = entries[SyncProtocol.TXTKey.deviceKind]
            .flatMap(SyncDeviceKind.init(rawValue:)) ?? .other

        return DiscoveredPeer(
            deviceID: deviceID,
            displayName: sanitizeDisplayName(entries[SyncProtocol.TXTKey.displayName], fallback: kind.displayName),
            kind: kind,
            protocolVersion: version,
            isPairingOpen: entries[SyncProtocol.TXTKey.pairingOpen] == "1",
            endpointDescription: endpointDescription
        )
    }

    static func parseVersion(_ raw: String?) -> SyncProtocol.Version? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ".")
        guard parts.count == 2,
              let major = Int(parts[0]), let minor = Int(parts[1]),
              major >= 0, minor >= 0 else { return nil }
        return SyncProtocol.Version(major: major, minor: minor)
    }

    /// A peer's name is attacker-controlled text that goes straight into the
    /// UI. Strip control characters and anything that could be used to fake
    /// interface chrome, and clamp the length so a very long name cannot push
    /// the rest of a row off screen.
    static func sanitizeDisplayName(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        let cleaned = raw
            .precomposedStringWithCanonicalMapping
            .unicodeScalars
            .filter { scalar in
                // Control characters, and the bidirectional-override scalars
                // that let a name render as something other than what it is.
                !CharacterSet.controlCharacters.contains(scalar)
                    && !(0x202A ... 0x202E).contains(scalar.value)
                    && !(0x2066 ... 0x2069).contains(scalar.value)
            }
        let string = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? fallback : String(string.prefix(63))
    }

    private static func clamp(_ value: String) -> String {
        var result = value
        while result.utf8.count > maxValueBytes { result = String(result.dropLast()) }
        return result
    }
}
