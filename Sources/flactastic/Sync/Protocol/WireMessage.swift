import Foundation

/// Every control message that can cross a sync connection.
///
/// Encoded as JSON with an explicit `"t"` discriminator and a `"d"` payload,
/// rather than relying on Swift's synthesised enum encoding. Swift's shape
/// (`{"fileStart":{"_0":{…}}}`) is an implementation detail of the compiler,
/// and this format is a published contract that a future Linux, Windows, or
/// non-Swift implementation has to reproduce from `docs/sync-protocol-v1.md`.
/// Writing the coding by hand keeps the document and the code honest.
///
/// New cases are additive. A peer that receives an unknown discriminator
/// replies with `.protocolError(.unsupportedMessage)` and closes, rather than
/// guessing.
enum WireMessage: Sendable, Equatable {

    // MARK: Handshake
    case hello(Hello)
    case helloAck(Hello)

    // MARK: Pairing (only accepted while a pairing code is live)
    case pairCommit(PairCommit)
    case pairGuestKey(PairGuestKey)
    case pairReveal(PairReveal)
    case pairConfirm(PairConfirm)
    case pairResult(PairResult)

    // MARK: Sync negotiation
    /// Sender → receiver: "here is my filtered library, in this direction."
    case syncRequest(SyncRequest)
    /// Receiver → sender: "this is what that would do to me."
    case planProposal(PlanProposal)
    /// Sender → receiver: the user's decision on that plan.
    case planDecision(PlanDecision)

    // MARK: Transfer
    case fileStart(FileStart)
    /// Receiver → sender, gating each file and carrying the resume offset.
    case fileAccept(FileAccept)
    case fileEnd(FileEnd)
    case playlists(PlaylistPayload)
    case syncComplete(Completion)

    // MARK: Control
    case cancel(Cancellation)
    case protocolError(ProtocolFailure)

    // MARK: - Payloads

    struct Hello: Codable, Sendable, Equatable {
        let version: SyncProtocol.Version
        let deviceID: UUID
        let displayName: String
        let deviceKind: SyncDeviceKind
        /// Whether this device already holds a pairing key for the peer. Lets
        /// the UI offer "Pair" versus "Sync" before any secret is exchanged.
        ///
        /// `false` is also how a guest opens a pairing attempt: the host reads
        /// it and answers with `pairCommit`.
        let isPaired: Bool
        /// `ChannelBinding.proof` for this connection. Required when
        /// `isPaired` is true — it is what stops a device that dialled with
        /// the public pairing key from passing itself off as a paired peer.
        var proof: Data? = nil
    }

    /// Step 2 of pairing: `SHA256(hostPublicKey ‖ hostNonce)`.
    ///
    /// Committing before seeing the guest's key is the whole point — it stops
    /// an active man-in-the-middle from choosing its key to match a guessed
    /// code, holding it to a single online attempt.
    struct PairCommit: Codable, Sendable, Equatable {
        let commitment: Data
    }

    /// Step 3: the guest's X25519 public key.
    struct PairGuestKey: Codable, Sendable, Equatable {
        let publicKey: Data
    }

    /// Step 4: the host opens its commitment.
    struct PairReveal: Codable, Sendable, Equatable {
        let publicKey: Data
        let nonce: Data
    }

    /// Step 6: `HMAC(derivedKey, code ‖ role)`, plus the identity this device
    /// wants recorded. Identity is only trusted once the MAC verifies.
    struct PairConfirm: Codable, Sendable, Equatable {
        let mac: Data
        let deviceID: UUID
        let displayName: String
        let deviceKind: SyncDeviceKind
    }

    struct PairResult: Codable, Sendable, Equatable {
        let success: Bool
        /// Present on failure. Deliberately coarse — never echo back how close
        /// a guessed code was.
        let failureReason: String?
    }

    struct SyncRequest: Codable, Sendable, Equatable {
        /// Direction as the *initiating* device means it. The receiver inverts
        /// it to describe its own role.
        let direction: SyncDirection
        let filter: SyncFilter
        let manifest: LibraryManifest
    }

    struct PlanProposal: Codable, Sendable, Equatable {
        let plan: SyncPlan
        /// Free space on the receiver, so the sender can warn before starting
        /// rather than failing three quarters of the way through.
        let receiverFreeBytes: Int64?
    }

    struct PlanDecision: Codable, Sendable, Equatable {
        /// Echoes `SyncPlan.planHash`. The receiver recomputes its plan and
        /// refuses if the hash no longer matches — the library may have
        /// changed while the confirmation sheet was on screen.
        let planHash: String
        let approved: Bool
        /// The part of the plan the user ticked. `nil` means all of it. Both
        /// sides narrow the plan identically with `SyncPlan.restricted(to:)`
        /// *after* checking `planHash` against the full plan — a selection can
        /// only remove work, never add any.
        var selection: SyncSelection? = nil
    }

    struct FileStart: Codable, Sendable, Equatable {
        let trackID: UUID
        /// Path relative to the **sender's** root. Untrusted; the receiver runs
        /// it through `PathSanitizer` and may place the file somewhere else
        /// entirely (e.g. re-derived through an Organizer profile).
        let relativePath: String
        let fileSize: Int64
        let contentHash: String
        let tagFingerprint: String
    }

    struct FileAccept: Codable, Sendable, Equatable {
        let trackID: UUID
        /// Bytes the receiver already holds and has verified. The sender seeks
        /// here. Zero for a fresh transfer; refuse the file with `skip`.
        let resumeOffset: Int64
        let skip: Bool
    }

    struct FileEnd: Codable, Sendable, Equatable {
        let trackID: UUID
    }

    /// Playlists travel whole, as the existing `Playlist` Codable form —
    /// `Library/Playlist.swift` is byte-identical across the two repos, so no
    /// translation layer is needed or wanted.
    struct PlaylistPayload: Codable, Sendable, Equatable {
        let playlists: [Playlist]
    }

    struct Completion: Codable, Sendable, Equatable {
        let tracksTransferred: Int
        let playlistsTransferred: Int
        let bytesTransferred: Int64
    }

    struct Cancellation: Codable, Sendable, Equatable {
        let reason: String
    }

    struct ProtocolFailure: Codable, Sendable, Equatable {
        let code: Code
        let message: String

        enum Code: String, Codable, Sendable, Equatable {
            case incompatibleVersion
            case notPaired
            case pairingClosed
            case pairingFailed
            case rateLimited
            case unsupportedMessage
            case unexpectedMessage
            case invalidPath
            case hashMismatch
            case sizeExceeded
            case insufficientStorage
            case planStale
            case internalFailure
        }
    }
}

// MARK: - Codable

extension WireMessage: Codable {

    /// Discriminator values. **These strings are the wire contract** — renaming
    /// a Swift case is free, renaming one of these is a protocol break.
    private enum Tag: String, Codable {
        case hello, helloAck
        case pairCommit, pairGuestKey, pairReveal, pairConfirm, pairResult
        case syncRequest, planProposal, planDecision
        case fileStart, fileAccept, fileEnd, playlists, syncComplete
        case cancel, protocolError
    }

    private enum CodingKeys: String, CodingKey {
        case tag = "t"
        case data = "d"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .tag)
        switch tag {
        case .hello:         self = .hello(try c.decode(Hello.self, forKey: .data))
        case .helloAck:      self = .helloAck(try c.decode(Hello.self, forKey: .data))
        case .pairCommit:    self = .pairCommit(try c.decode(PairCommit.self, forKey: .data))
        case .pairGuestKey:  self = .pairGuestKey(try c.decode(PairGuestKey.self, forKey: .data))
        case .pairReveal:    self = .pairReveal(try c.decode(PairReveal.self, forKey: .data))
        case .pairConfirm:   self = .pairConfirm(try c.decode(PairConfirm.self, forKey: .data))
        case .pairResult:    self = .pairResult(try c.decode(PairResult.self, forKey: .data))
        case .syncRequest:   self = .syncRequest(try c.decode(SyncRequest.self, forKey: .data))
        case .planProposal:  self = .planProposal(try c.decode(PlanProposal.self, forKey: .data))
        case .planDecision:  self = .planDecision(try c.decode(PlanDecision.self, forKey: .data))
        case .fileStart:     self = .fileStart(try c.decode(FileStart.self, forKey: .data))
        case .fileAccept:    self = .fileAccept(try c.decode(FileAccept.self, forKey: .data))
        case .fileEnd:       self = .fileEnd(try c.decode(FileEnd.self, forKey: .data))
        case .playlists:     self = .playlists(try c.decode(PlaylistPayload.self, forKey: .data))
        case .syncComplete:  self = .syncComplete(try c.decode(Completion.self, forKey: .data))
        case .cancel:        self = .cancel(try c.decode(Cancellation.self, forKey: .data))
        case .protocolError: self = .protocolError(try c.decode(ProtocolFailure.self, forKey: .data))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let p):         try c.encode(Tag.hello, forKey: .tag);         try c.encode(p, forKey: .data)
        case .helloAck(let p):      try c.encode(Tag.helloAck, forKey: .tag);      try c.encode(p, forKey: .data)
        case .pairCommit(let p):    try c.encode(Tag.pairCommit, forKey: .tag);    try c.encode(p, forKey: .data)
        case .pairGuestKey(let p):  try c.encode(Tag.pairGuestKey, forKey: .tag);  try c.encode(p, forKey: .data)
        case .pairReveal(let p):    try c.encode(Tag.pairReveal, forKey: .tag);    try c.encode(p, forKey: .data)
        case .pairConfirm(let p):   try c.encode(Tag.pairConfirm, forKey: .tag);   try c.encode(p, forKey: .data)
        case .pairResult(let p):    try c.encode(Tag.pairResult, forKey: .tag);    try c.encode(p, forKey: .data)
        case .syncRequest(let p):   try c.encode(Tag.syncRequest, forKey: .tag);   try c.encode(p, forKey: .data)
        case .planProposal(let p):  try c.encode(Tag.planProposal, forKey: .tag);  try c.encode(p, forKey: .data)
        case .planDecision(let p):  try c.encode(Tag.planDecision, forKey: .tag);  try c.encode(p, forKey: .data)
        case .fileStart(let p):     try c.encode(Tag.fileStart, forKey: .tag);     try c.encode(p, forKey: .data)
        case .fileAccept(let p):    try c.encode(Tag.fileAccept, forKey: .tag);    try c.encode(p, forKey: .data)
        case .fileEnd(let p):       try c.encode(Tag.fileEnd, forKey: .tag);       try c.encode(p, forKey: .data)
        case .playlists(let p):     try c.encode(Tag.playlists, forKey: .tag);     try c.encode(p, forKey: .data)
        case .syncComplete(let p):  try c.encode(Tag.syncComplete, forKey: .tag);  try c.encode(p, forKey: .data)
        case .cancel(let p):        try c.encode(Tag.cancel, forKey: .tag);        try c.encode(p, forKey: .data)
        case .protocolError(let p): try c.encode(Tag.protocolError, forKey: .tag); try c.encode(p, forKey: .data)
        }
    }

    // MARK: - Serialisation

    /// ISO-8601 **with fractional seconds**, and `Data` as base64. Both are
    /// stated explicitly because the Foundation defaults have changed between
    /// OS versions and a future non-Apple implementation needs a fixed target
    /// to write against.
    ///
    /// The fractional part is not cosmetic. Plain `.iso8601` truncates to whole
    /// seconds, so a playlist round-tripping through a sync would come back
    /// with a `dateCreated` a few hundred milliseconds earlier than it left —
    /// and syncing the same library back and forth would walk the timestamp
    /// backwards on every run.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Deterministic key order. Two encodes of equal values must produce
        // identical bytes — that is what lets the transport dedupe, lets the
        // spec document quote real output, and makes a wire capture diffable
        // when a peer misbehaves.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        encoder.dataEncodingStrategy = .base64
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = dateFormatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected ISO-8601 date with fractional seconds, got \(text)."
                ))
            }
            return date
        }
        decoder.dataDecodingStrategy = .base64
        return decoder
    }

    func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    static func decoded(from data: Data) throws -> WireMessage {
        try makeDecoder().decode(WireMessage.self, from: data)
    }
}
