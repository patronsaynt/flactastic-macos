import Foundation
import Darwin
import Observation

/// Pushes the currently-playing track to the local Discord desktop client via
/// the IPC socket at `$TMPDIR/discord-ipc-{0..9}`. Silently no-ops when Discord
/// isn't running and reconnects with backoff when it appears.
///
/// The user-visible "Listening to FLACtastic" label and the large artwork are
/// driven by the Discord Application configured at the ID below. Replace the
/// placeholder with the real ID created at https://discord.com/developers/applications
/// and upload an asset named `flactastic_logo` for the album-art slot.
@MainActor
@Observable
final class DiscordPresenceService {
    // TODO: Replace with the FLACtastic Discord Application ID.
    private static let clientID = "1498596791971741756"

    private let ipc = DiscordIPC()
    private let artworkLookup = AlbumArtworkLookup()
    private var watcher: Task<Void, Never>?
    private weak var player: PlayerState?
    private weak var settings: Settings?

    init() {}

    func attach(player: PlayerState, settings: Settings) {
        self.player = player
        self.settings = settings
        watcher?.cancel()
        let clientID = Self.clientID
        watcher = Task { [weak self] in
            await self?.ipc.setClientID(clientID)
            await self?.runLoop()
        }
    }

    /// Dedupe key — equality controls whether we push a fresh `SET_ACTIVITY`.
    /// Keep this minimal: timestamps drift each poll due to float jitter, and
    /// Discord rate-limits to ~5 updates per 20s, so including them silently
    /// drops genuine track-change updates.
    private struct SnapshotKey: Equatable, Sendable {
        let activeTrackID: UUID?   // nil when paused, stopped, or disabled
        let enabled: Bool
        let hasTimestamps: Bool    // re-send once duration becomes known
    }

    private struct Snapshot: Sendable {
        let key: SnapshotKey
        let title: String
        let artist: String
        let album: String
        let rawArtist: String     // for artwork lookup
        let rawAlbum: String
        let startUnixMs: Int64?
        let endUnixMs: Int64?
    }

    private var lastKey: SnapshotKey?
    private var lastStartMs: Int64?

    /// Threshold (ms) for treating a `startMs` change as a real seek vs. float
    /// jitter from polling. Normal playback drifts a few hundred ms between
    /// 2-second polls; a rewind/scrub jumps multiple seconds.
    private static let seekDriftThresholdMs: Int64 = 1500

    private func runLoop() async {
        while !Task.isCancelled {
            let snap = makeSnapshot()
            let seeked: Bool = {
                guard let new = snap.startUnixMs, let old = lastStartMs else { return false }
                return abs(new - old) >= Self.seekDriftThresholdMs
            }()
            if snap.key != lastKey || seeked {
                let ok: Bool
                if snap.key.enabled, snap.key.activeTrackID != nil {
                    let artURL = await artworkLookup.url(artist: snap.rawArtist, album: snap.rawAlbum)
                    ok = await ipc.setActivity(
                        details: snap.title,
                        state: snap.artist,
                        album: snap.album,
                        artworkURL: artURL,
                        startMs: snap.startUnixMs,
                        endMs: snap.endUnixMs
                    )
                } else {
                    ok = await ipc.clearActivity()
                }
                // Only commit the key on success — otherwise a transient write
                // failure (Discord restart, broken pipe) would mark the change
                // "delivered" and we'd never retry until the track changes again.
                if ok {
                    lastKey = snap.key
                    lastStartMs = snap.startUnixMs
                }
            }
            // Adaptive cadence: the 2 s poll only exists to catch seeks during
            // active playback. When presence is disabled or nothing is playing
            // there is nothing to detect, so back off to 10 s — the app spends
            // most of its life idle, and a permanent 2 s wakeup defeats timer
            // coalescing/App Nap. Worst case: presence appears up to 10 s after
            // resuming from a long idle.
            let inactive = !snap.key.enabled || snap.key.activeTrackID == nil
            try? await Task.sleep(for: .seconds(inactive ? 10 : 2))
        }
    }

    private func makeSnapshot() -> Snapshot {
        let enabled = settings?.discordRichPresenceEnabled ?? true
        guard let p = player, let track = p.currentTrack, p.isPlaying else {
            return Snapshot(
                key: SnapshotKey(activeTrackID: nil, enabled: enabled, hasTimestamps: false),
                title: "", artist: "", album: "", rawArtist: "", rawAlbum: "",
                startUnixMs: nil, endUnixMs: nil
            )
        }
        let cur = p.currentTime
        let dur = p.duration ?? track.duration
        var startMs: Int64? = nil
        var endMs: Int64? = nil
        if let dur, dur > 0 {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let s = nowMs - Int64(cur * 1000)
            startMs = s
            endMs = s + Int64(dur * 1000)
        }
        // FLAC/Vorbis tags commonly join multiple artists with " ; " or ";".
        // Normalise to ", " so Discord shows "Artist1, Artist2" instead.
        let rawTag = track.artist ?? track.albumArtist ?? ""
        let artist = rawTag
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let album = track.album ?? ""
        // Keep the artist on the state line; album shows below as the large_text
        // (Discord renders it under the artwork), so duplicating it here is clutter.
        let displayState: String
        if !artist.isEmpty {
            displayState = "by \(artist)"
        } else if !album.isEmpty {
            displayState = album
        } else {
            displayState = ""
        }
        return Snapshot(
            key: SnapshotKey(activeTrackID: track.id, enabled: enabled, hasTimestamps: startMs != nil),
            title: track.title,
            artist: displayState,
            album: album,
            rawArtist: artist,
            rawAlbum: album,
            startUnixMs: startMs,
            endUnixMs: endMs
        )
    }
}

// MARK: - Album artwork lookup (iTunes Search API)
//
// Discord's RPC accepts arbitrary HTTPS URLs in `large_image`/`small_image`
// (proxied through Discord's media CDN). We resolve a per-album cover URL via
// Apple's keyless iTunes Search endpoint and pass it along; if no match is
// found we fall back to the FLACtastic logo asset uploaded in the Dev Portal.
private actor AlbumArtworkLookup {
    private var cache: [String: String?] = [:]

    func url(artist: String, album: String) async -> String? {
        let key = "\(artist.lowercased())|\(album.lowercased())"
        if let cached = cache[key] { return cached }
        let resolved = await fetch(artist: artist, album: album)
        cache[key] = resolved
        return resolved
    }

    private func fetch(artist: String, album: String) async -> String? {
        guard !album.isEmpty else { return nil }
        let term = artist.isEmpty ? album : "\(artist) \(album)"
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps.url else { return nil }
        struct Resp: Decodable { let results: [Result] }
        struct Result: Decodable { let artworkUrl100: String? }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            guard let small = decoded.results.first?.artworkUrl100 else { return nil }
            // Upgrade Apple's tiny 100×100 thumbnail to 512×512 for crisp art.
            return small.replacingOccurrences(of: "100x100bb", with: "512x512bb")
        } catch {
            return nil
        }
    }
}

// MARK: - IPC actor

private actor DiscordIPC {
    private var fd: Int32 = -1
    private var clientID: String?
    private var handshaked = false
    private var nextReconnectAt: Date = .distantPast
    private var backoff: TimeInterval = 1

    func setClientID(_ id: String) {
        clientID = id
    }

    /// Clamp a Discord activity string to the API's 2…128 UTF-8 byte range.
    /// Pads with a trailing space when too short; truncates on a Character
    /// boundary with a trailing "…" when too long.
    static func clampField(_ s: String) -> String {
        let maxBytes = 128
        if s.utf8.count <= maxBytes && s.utf8.count >= 2 { return s }
        if s.utf8.count < 2 { return s + " " }
        let ellipsis = "…"
        let budget = maxBytes - ellipsis.utf8.count
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > budget { break }
            out.append(ch)
            used += n
        }
        out.append(ellipsis)
        return out
    }

    func setActivity(details: String, state: String, album: String, artworkURL: String?, startMs: Int64?, endMs: Int64?) -> Bool {
        guard ensureConnected() else { return false }
        // Discord rejects the entire SET_ACTIVITY when any string field is < 2
        // bytes or > 128 bytes (UTF-8). Clamp to keep payloads accepted.
        // When we resolved a cover URL, use it as large_image and demote the
        // FLACtastic logo to the small overlay. Otherwise the logo stays large.
        var assets: [String: Any] = [:]
        if let artworkURL, !artworkURL.isEmpty {
            assets["large_image"] = artworkURL
            assets["large_text"] = Self.clampField(album.isEmpty ? "FLACtastic" : album)
            assets["small_image"] = "flactastic_logo"
            assets["small_text"] = "FLACtastic"
        } else {
            assets["large_image"] = "flactastic_logo"
            assets["large_text"] = Self.clampField(album.isEmpty ? "FLACtastic" : album)
        }
        var activity: [String: Any] = [
            "type": 2,
            "details": Self.clampField(details.isEmpty ? "Unknown Track" : details),
            "state": Self.clampField(state.isEmpty ? "FLACtastic" : state),
            "assets": assets
        ]
        if let s = startMs, let e = endMs {
            activity["timestamps"] = ["start": s, "end": e]
        }
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "nonce": UUID().uuidString,
            "args": [
                "pid": Int(getpid()),
                "activity": activity
            ]
        ]
        if !sendFrame(opcode: 1, json: payload) {
            dropConnection()
            return false
        }
        drainReplies()
        return true
    }

    func clearActivity() -> Bool {
        guard ensureConnected() else { return false }
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "nonce": UUID().uuidString,
            "args": [
                "pid": Int(getpid()),
                "activity": NSNull()
            ]
        ]
        if !sendFrame(opcode: 1, json: payload) {
            dropConnection()
            return false
        }
        drainReplies()
        return true
    }

    func disconnect() {
        dropConnection()
    }

    // MARK: connection

    private func ensureConnected() -> Bool {
        if fd >= 0 && handshaked { return true }
        if Date() < nextReconnectAt { return false }
        guard let id = clientID else { return false }
        if connectSocket() && performHandshake(clientID: id) {
            backoff = 1
            return true
        }
        dropConnection()
        nextReconnectAt = Date().addingTimeInterval(backoff)
        backoff = min(backoff * 2, 30)
        return false
    }

    private func dropConnection() {
        if fd >= 0 { close(fd) }
        fd = -1
        handshaked = false
    }

    private func connectSocket() -> Bool {
        let tmp = NSTemporaryDirectory()
        let pathCap = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size - 1
        for n in 0...9 {
            let path = "\(tmp)discord-ipc-\(n)"
            guard path.utf8.count <= pathCap else { continue }

            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { continue }
            configureSocket(s)

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: pathCap + 1) { dest in
                    _ = path.withCString { src in
                        strlcpy(dest, src, pathCap + 1)
                    }
                }
            }

            let sz = socklen_t(MemoryLayout<sockaddr_un>.size)
            let r = withUnsafePointer(to: &addr) { aPtr -> Int32 in
                aPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(s, sa, sz)
                }
            }
            if r == 0 {
                fd = s
                return true
            }
            close(s)
        }
        return false
    }

    /// Without SO_NOSIGPIPE, writing to a socket Discord has already closed
    /// (Discord quit/restarted, or dropped us) raises SIGPIPE, whose default
    /// action terminates the whole app mid-playback. With it, `write` just
    /// fails with EPIPE and we reconnect via the normal backoff path.
    /// The timeouts keep a wedged Discord from blocking this actor forever.
    private func configureSocket(_ s: Int32) {
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        let tvSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, tvSize)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, tvSize)
    }

    /// Discord answers every SET_ACTIVITY with a response frame. Consume them
    /// so they don't pile up in the socket buffer over a long session, and use
    /// the read to notice early when Discord has hung up (recv returns 0).
    private func drainReplies() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let r = buf.withUnsafeMutableBytes { bp in
                recv(fd, bp.baseAddress, bp.count, MSG_DONTWAIT)
            }
            if r > 0 { continue }
            if r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
            dropConnection()
            return
        }
    }

    private func performHandshake(clientID: String) -> Bool {
        let payload: [String: Any] = ["v": 1, "client_id": clientID]
        guard sendFrame(opcode: 0, json: payload) else { return false }
        // Read and discard the READY frame so the socket buffer doesn't fill.
        // If the read fails the connection is dead; bail out.
        guard readFrame() != nil else { return false }
        handshaked = true
        return true
    }

    // MARK: framing

    @discardableResult
    private func sendFrame(opcode: UInt32, json: [String: Any]) -> Bool {
        guard fd >= 0,
              let body = try? JSONSerialization.data(withJSONObject: json, options: [])
        else { return false }

        var op = opcode.littleEndian
        var len = UInt32(body.count).littleEndian
        var frame = Data()
        withUnsafeBytes(of: &op) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(body)

        return frame.withUnsafeBytes { raw -> Bool in
            var remaining = raw.count
            var ptr = raw.baseAddress
            while remaining > 0 {
                let w = Darwin.write(fd, ptr, remaining)
                if w <= 0 { return false }
                remaining -= w
                ptr = ptr?.advanced(by: w)
            }
            return true
        }
    }

    private func readFrame() -> Data? {
        var header = [UInt8](repeating: 0, count: 8)
        if !readExact(into: &header, count: 8) { return nil }
        let len = Int(UInt32(header[4])
                      | UInt32(header[5]) << 8
                      | UInt32(header[6]) << 16
                      | UInt32(header[7]) << 24)
        guard len >= 0, len < 1_000_000 else { return nil }
        if len == 0 { return Data() }
        var body = [UInt8](repeating: 0, count: len)
        if !readExact(into: &body, count: len) { return nil }
        return Data(body)
    }

    private func readExact(into buf: inout [UInt8], count: Int) -> Bool {
        var got = 0
        while got < count {
            let r = buf.withUnsafeMutableBufferPointer { bp -> Int in
                guard let base = bp.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: got), count - got)
            }
            if r <= 0 { return false }
            got += r
        }
        return true
    }
}
