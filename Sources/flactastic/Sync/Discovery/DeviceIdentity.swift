import Foundation

/// This device's stable, non-identifying identity on the network.
///
/// The ID is a random UUID generated once and kept in UserDefaults. It is
/// deliberately *not* derived from anything real — not the hostname, not the
/// hardware UUID, not the user's name — because it is broadcast in the clear in
/// a Bonjour TXT record to anyone on the Wi-Fi, including networks the user
/// does not control. A random UUID lets a paired peer recognise us again and
/// tells a stranger nothing.
///
/// The display name is the one piece of real information advertised, because
/// the user has to be able to tell their own Mac from a neighbour's in the
/// device list. It is user-overridable for exactly that reason.
@MainActor
enum DeviceIdentity {

    private static let idKey = "flactastic.sync.deviceID"
    private static let nameKey = "flactastic.sync.deviceName"

    /// Stable random identifier for this installation. Regenerating it makes
    /// every existing pairing unrecognisable, so it is only reset when the user
    /// explicitly forgets all peers.
    static var deviceID: UUID {
        if let stored = UserDefaults.standard.string(forKey: idKey),
           let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let fresh = UUID()
        UserDefaults.standard.set(fresh.uuidString, forKey: idKey)
        return fresh
    }

    /// What other devices call this one. Defaults to the machine's local
    /// network name, which is what the user already sees in Finder's sidebar
    /// and in AirDrop, so it needs no explanation.
    static var displayName: String {
        get {
            if let custom = UserDefaults.standard.string(forKey: nameKey),
               !custom.trimmingCharacters(in: .whitespaces).isEmpty {
                return custom
            }
            let hostName = Host.current().localizedName ?? ""
            return hostName.isEmpty ? "Mac" : hostName
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: nameKey)
            } else {
                // Bonjour TXT values are bounded; a very long name would be
                // truncated by the DNS layer in a way we cannot control, so
                // clamp it somewhere legible instead.
                UserDefaults.standard.set(String(trimmed.prefix(63)), forKey: nameKey)
            }
        }
    }

    static let kind: SyncDeviceKind = .mac

    /// Resets identity. Only for "forget all devices" — every peer that has
    /// paired with us will see this installation as a brand-new, unpaired
    /// device afterwards.
    static func regenerate() {
        UserDefaults.standard.removeObject(forKey: idKey)
    }
}

/// A peer seen on the network but not necessarily connected to or trusted.
///
/// Everything here comes from an unauthenticated TXT record that anyone on the
/// LAN can write, so nothing in it may be believed. `displayName` in particular
/// is attacker-controlled text — a hostile device can call itself whatever the
/// user's real Mac is called. That is precisely why pairing shows a code the
/// user reads off the *other machine's screen* rather than asking them to
/// recognise a name in a list.
struct DiscoveredPeer: Sendable, Identifiable, Hashable {
    let deviceID: UUID
    let displayName: String
    let kind: SyncDeviceKind
    let protocolVersion: SyncProtocol.Version
    /// Whether the peer says it is currently showing a pairing code.
    let isPairingOpen: Bool
    /// Opaque handle used to connect. Not comparable across browse sessions.
    let endpointDescription: String

    var id: UUID { deviceID }

    var isCompatible: Bool {
        SyncProtocol.version.isCompatible(with: protocolVersion)
    }
}
