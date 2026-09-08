import Foundation

/// The framing layer: `[type: u8][length: u32 big-endian][payload]`.
///
/// Control messages (JSON) and file chunks (raw bytes) share one connection, so
/// every message is tagged and length-prefixed. Big-endian because it is the
/// conventional network byte order and leaves no ambiguity for a future port on
/// a big-endian or non-Apple platform.
///
/// This type is deliberately **pure** — no `Network` import, no I/O. The
/// `NWProtocolFramer` adapter that plugs it into a live connection lives in
/// `Sync/Transport/`. Keeping the parser separate is what makes the hostile
/// inputs (truncated headers, oversized lengths, split payloads) cheap to test.
enum FrameCodec {

    /// Bytes of fixed header preceding every payload.
    static let headerBytes = 5

    // MARK: - Frame

    enum FrameType: UInt8, Sendable, Hashable, CaseIterable {
        /// JSON-encoded `WireMessage`.
        case control = 1
        /// Raw bytes of the file transfer currently in progress. The chunk
        /// carries no header of its own: the preceding `.fileStart` control
        /// message establishes which file and where the offset begins, and
        /// chunks arrive strictly in order.
        case fileChunk = 2

        /// Per-type payload ceiling. Enforced during decode so a hostile length
        /// prefix is rejected before we reserve any memory for it.
        var maxPayloadBytes: Int {
            switch self {
            case .control:   return SyncProtocol.maxControlFrameBytes
            case .fileChunk: return SyncProtocol.fileChunkBytes
            }
        }
    }

    struct Frame: Sendable, Equatable {
        let type: FrameType
        let payload: Data
    }

    // MARK: - Errors

    enum DecodeError: Error, Equatable, CustomStringConvertible {
        case unknownFrameType(UInt8)
        case payloadTooLarge(type: FrameType, declared: Int, limit: Int)

        var description: String {
            switch self {
            case .unknownFrameType(let raw):
                return "Unknown frame type \(raw)."
            case .payloadTooLarge(let type, let declared, let limit):
                return "\(type) frame declares \(declared) bytes, limit is \(limit)."
            }
        }
    }

    enum EncodeError: Error, Equatable, CustomStringConvertible {
        case payloadTooLarge(type: FrameType, size: Int, limit: Int)

        var description: String {
            switch self {
            case .payloadTooLarge(let type, let size, let limit):
                return "Cannot encode \(size)-byte \(type) frame; limit is \(limit)."
            }
        }
    }

    // MARK: - Encoding

    static func encode(_ frame: Frame) throws -> Data {
        let limit = frame.type.maxPayloadBytes
        guard frame.payload.count <= limit else {
            throw EncodeError.payloadTooLarge(type: frame.type, size: frame.payload.count, limit: limit)
        }
        var out = Data(capacity: headerBytes + frame.payload.count)
        out.append(frame.type.rawValue)
        var length = UInt32(frame.payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(frame.payload)
        return out
    }

    static func encodeControl(_ message: WireMessage) throws -> Data {
        try encode(Frame(type: .control, payload: try message.encoded()))
    }

    // MARK: - Incremental decoding

    /// Accumulates bytes from a stream and yields whole frames as they
    /// complete. A stream never delivers message boundaries, so the decoder
    /// must tolerate a header split across two reads and a payload split
    /// across many.
    struct Decoder {
        private var buffer = Data()

        init() {}

        /// Bytes buffered but not yet forming a complete frame. Exposed for
        /// tests and for the transport's watchdog, which treats an
        /// indefinitely growing buffer as a stalled peer.
        var pendingByteCount: Int { buffer.count }

        mutating func append(_ data: Data) {
            buffer.append(data)
        }

        /// Returns the next complete frame, or `nil` when more bytes are
        /// needed. Throws as soon as the *header* is malformed — an invalid
        /// length is rejected without waiting for (or allocating) the payload
        /// it claims.
        mutating func next() throws -> Frame? {
            guard buffer.count >= headerBytes else { return nil }

            let header = buffer.prefix(headerBytes)
            let bytes = [UInt8](header)

            guard let type = FrameType(rawValue: bytes[0]) else {
                throw DecodeError.unknownFrameType(bytes[0])
            }
            let declared = Int(UInt32(bytes[1]) << 24
                             | UInt32(bytes[2]) << 16
                             | UInt32(bytes[3]) << 8
                             | UInt32(bytes[4]))
            let limit = type.maxPayloadBytes
            guard declared <= limit else {
                throw DecodeError.payloadTooLarge(type: type, declared: declared, limit: limit)
            }

            guard buffer.count >= headerBytes + declared else { return nil }

            let payloadStart = buffer.startIndex + headerBytes
            let payloadEnd = payloadStart + declared
            let payload = Data(buffer[payloadStart ..< payloadEnd])
            buffer.removeSubrange(buffer.startIndex ..< payloadEnd)
            return Frame(type: type, payload: payload)
        }

        /// Drains every frame currently available.
        mutating func drain() throws -> [Frame] {
            var frames: [Frame] = []
            while let frame = try next() { frames.append(frame) }
            return frames
        }
    }
}
