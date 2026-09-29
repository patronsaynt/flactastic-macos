import Foundation

/// Constants shared by every FLACtastic sync implementation.
///
/// This file — and everything else under `Sync/Protocol/` — is the wire
/// contract. It is hand-ported verbatim into the iOS repo (the same way
/// `Library/Playlist.swift` and `Persistence/TrackIDStore.swift` already are)
/// and is the normative reference for `docs/sync-protocol-v1.md`. Nothing here
/// may import AppKit, UIKit, or Network: it must stay compilable on any
/// platform that has Foundation, so a future Linux/Windows port can reuse it
/// unchanged.
///
/// **Changing any value in this file is a protocol change.** Bump
/// `SyncProtocol.version` and update the spec document in both repos.
enum SyncProtocol {

    // MARK: - Versioning

    /// Wire format version. Peers exchange this in the first frame of every
    /// connection. A mismatched *major* version is fatal — there is no
    /// negotiation fallback, because silently syncing under a format one side
    /// misunderstands is worse than refusing.
    static let version = Version(major: 1, minor: 0)

    /// Oldest major version this build can still talk to.
    static let minimumCompatibleMajor = 1

    struct Version: Codable, Sendable, Hashable, CustomStringConvertible {
        let major: Int
        let minor: Int

        var description: String { "\(major).\(minor)" }

        /// Majors must match exactly; minors are additive and always accepted.
        func isCompatible(with other: Version) -> Bool {
            major == other.major
                && major >= SyncProtocol.minimumCompatibleMajor
        }
    }

    // MARK: - Discovery

    /// Bonjour service type. Registered under the local domain only — this
    /// feature never leaves the LAN.
    static let bonjourServiceType = "_flactastic._tcp"
    static let bonjourDomain = "local."

    /// TXT record keys. Deliberately minimal: a device broadcasting on an
    /// untrusted network reveals only that FLACtastic is running and what to
    /// call it. Never add library contents, usernames, or paths here.
    enum TXTKey {
        static let protocolVersion = "v"      // "1.0"
        static let deviceID        = "id"     // UUID string
        static let displayName     = "n"      // user-visible device name
        static let deviceKind      = "k"      // SyncDeviceKind raw value
        static let pairingOpen     = "p"      // "1" while a pairing code is live
    }

    // MARK: - Size limits

    /// Control frames are JSON and are read fully into memory, so they are
    /// capped hard. 8 MiB comfortably fits a manifest for a very large library
    /// plus playlist artwork; anything beyond it is treated as hostile.
    static let maxControlFrameBytes = 8 * 1024 * 1024

    /// File payload chunk size. Also the maximum accepted chunk length — a
    /// peer that declares more is a protocol error.
    static let fileChunkBytes = 1024 * 1024

    /// Upper bound on a single transferred file (2 GiB). Well past any real
    /// audio file, including long DSD-sourced FLAC transfers, while still
    /// bounding what a malicious peer can make us allocate on disk.
    static let maxFileBytes: Int64 = 2 * 1024 * 1024 * 1024

    // MARK: - Pairing

    /// Digits in a pairing code. Eight digits gives 10^8 possibilities; the
    /// commitment scheme in `PairingSession` limits an active attacker to a
    /// single online guess, so this is comfortably sufficient.
    static let pairingCodeDigits = 8

    /// HKDF info strings. These are part of the wire contract — two peers that
    /// disagree on them derive different keys and fail the handshake.
    static let pairingKDFInfo = "flactastic-pair-v1"
    static let sessionKDFInfo = "flactastic-session-v1"

    /// How long a displayed pairing code stays valid.
    static let pairingCodeLifetime: TimeInterval = 120

    /// Consecutive failed pairing attempts before the listener locks out.
    static let pairingFailureLimit = 3
    static let pairingLockoutDuration: TimeInterval = 60

    // MARK: - Timeouts

    /// How long an initiator waits for the responder's manifest. The responder
    /// hashes its whole library before it can send one, which on a first sync
    /// of a large FLAC collection is minutes, not seconds. Later runs hit the
    /// hash cache and answer almost immediately.
    static let manifestWaitTimeout: Duration = .seconds(30 * 60)

    /// How long a responder waits for the initiator's decision. A person is
    /// working through a checklist of what to sync, possibly a long one.
    static let planReviewTimeout: Duration = .seconds(30 * 60)
}

/// What kind of machine a peer is. Advertised in the TXT record so the UI can
/// pick an icon before any connection is made.
enum SyncDeviceKind: String, Codable, Sendable, Hashable, CaseIterable {
    case mac
    case iPhone
    case iPad
    case other

    var displayName: String {
        switch self {
        case .mac:    return "Mac"
        case .iPhone: return "iPhone"
        case .iPad:   return "iPad"
        case .other:  return "Device"
        }
    }
}

/// Which way the bytes flow in a single sync run. The user picks one per run;
/// bi-directional convergence is two runs. Named from the point of view of the
/// device the user is operating.
enum SyncDirection: String, Codable, Sendable, Hashable {
    /// Local library is the source of truth; the remote receives.
    case push
    /// Remote library is the source of truth; the local device receives.
    case pull

    var inverted: SyncDirection { self == .push ? .pull : .push }
}
