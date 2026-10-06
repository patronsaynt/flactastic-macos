import Foundation
import os

/// Timing log for diagnosing renderer latency:
/// `log stream --predicate 'subsystem == "com.flactastic.app" && category == "Cast"'`
let castLog = Logger(subsystem: "com.flactastic.app", category: "Cast")

/// Plays the engine's queue on one DLNA/UPnP renderer.
///
/// The renderer *pulls* each track from `MediaHTTPServer`, so the audio is the
/// original file (bit-perfect) and is buffered on the device — Wi-Fi jitter
/// never reaches the DAC. The next track is pre-armed with
/// `SetNextAVTransportURI` so transitions are gapless and need no round-trip.
///
/// All SOAP commands run strictly in order through one chain; polling runs
/// alongside it once a second and is the only source of position/state.
@MainActor
final class DLNARendererSession: RemotePlaybackTarget {
    let renderer: UPnPRendererDescription
    weak var engine: PlayerEngine?

    /// Called once when the renderer stops answering for long enough that the
    /// session should end. The message is user-facing.
    var onConnectionLost: ((String) -> Void)?
    /// Short user-facing status, e.g. while a capped track is being prepared.
    var onStatusChange: ((String?) -> Void)?

    private let soap = UPnPSOAPClient()
    private let server: MediaHTTPServer
    private let preparer: StreamPreparer
    private let capabilities: RendererCapabilities
    private let quality: NetworkStreamQuality
    private let baseURL: URL

    private var commandTail: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var armTask: Task<Void, Never>?

    /// Supersedes queued loads / seeks / arms when newer ones arrive, so
    /// mashing "next" doesn't make the renderer play through every skip.
    private var loadGeneration = 0
    private var seekGeneration = 0
    private var armGeneration = 0

    /// Path (token) of the URI currently set on the renderer, and the one
    /// pre-armed as next. Compared against `TrackURI` to detect advances.
    private var currentPath: String?
    private var nextPath: String?
    private var armedNextID: UUID?
    private var supportsSetNext: Bool

    /// Where the device should be once the last load/seek takes effect.
    /// Until a PLAYING report agrees with it, reports are treated as stale.
    private var expectedPosition: TimeInterval?
    /// When the last start (load/play/seek) was requested, for the log.
    private var startRequestedAt: Date?
    private var lastLoggedState: String?

    /// State reports right after a command are often stale (e.g. STOPPED
    /// while a new URI loads); ignore state flips until this passes.
    private var graceUntil = Date.distantPast
    private var lastPosition: TimeInterval = 0
    private var firstFailure: Date?
    private var isClosed = false

    static let lostConnectionAfter: TimeInterval = 10

    init(renderer: UPnPRendererDescription, server: MediaHTTPServer, preparer: StreamPreparer,
         capabilities: RendererCapabilities, quality: NetworkStreamQuality, baseURL: URL,
         supportsSetNext: Bool) {
        self.renderer = renderer
        self.supportsSetNext = supportsSetNext
        self.server = server
        self.preparer = preparer
        self.capabilities = capabilities
        self.quality = quality
        self.baseURL = baseURL
    }

    var supportsVolume: Bool { renderer.renderingControlURL != nil }

    // MARK: Lifecycle

    /// The renderer's current volume (0...1), or nil when it has no RenderingControl.
    func fetchVolume() async -> Float? {
        guard let url = renderer.renderingControlURL else { return nil }
        let values = try? await soap.call("GetVolume", service: UPnPRendererDescription.renderingControlType,
                                          url: url, [("InstanceID", "0"), ("Channel", "Master")])
        return values?["CurrentVolume"].flatMap(Float.init).map { $0 / 100 }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                // Watch closely while waiting for playback to start (so the
                // clock starts the moment audio does) and, without SetNext,
                // near the end — the next track only loads once we see
                // this one stop.
                let fast = (self.engine?.isAwaitingRemoteStart ?? false)
                    || (!self.supportsSetNext && self.isNearEnd)
                try? await Task.sleep(for: .milliseconds(fast ? 250 : 1000))
            }
        }
    }

    /// Stop the renderer and tear the session down.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        pollTask?.cancel()
        seekTask?.cancel()
        volumeTask?.cancel()
        armTask?.cancel()
        commandTail?.cancel()
        _ = try? await soap.call("Stop", service: UPnPRendererDescription.avTransportType,
                                 url: renderer.avTransportURL, [("InstanceID", "0")])
    }

    // MARK: RemotePlaybackTarget

    func load(_ track: Track, next: Track?, startAt: TimeInterval, autoplay: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        armGeneration += 1
        armTask?.cancel()
        nextPath = nil
        armedNextID = nil
        lastPosition = startAt
        expectedPosition = startAt
        noteStartRequested("load \"\(track.title)\" at \(Int(startAt))s")
        graceUntil = Date().addingTimeInterval(8)

        enqueue("load") { [self] in
            guard generation == loadGeneration else { return }
            let item = try await prepareItem(track)
            guard generation == loadGeneration else { return }

            currentPath = nil
            try await transport("SetAVTransportURI", [
                ("CurrentURI", item.url.absoluteString),
                ("CurrentURIMetaData", item.metadata),
            ])
            currentPath = item.url.path

            if autoplay || startAt > 1 {
                try await transport("Play", [("Speed", "1")])
            }
            if startAt > 1 {
                // A seek is only accepted once the renderer has opened the
                // media, and slow devices take seconds to — wait until it
                // says it's playing rather than guessing a delay.
                await waitUntilPlaying(timeout: 15)
                guard generation == loadGeneration else { return }
                try? await seekNow(to: startAt)
                if !autoplay { try? await transport("Pause") }
            }
            graceUntil = Date().addingTimeInterval(3)
            onStatusChange?(nil)
        }
        setNext(next)
    }

    func play() {
        expectedPosition = engine?.currentTime
        noteStartRequested("play")
        graceUntil = Date().addingTimeInterval(3)
        enqueue("play") { [self] in try await transport("Play", [("Speed", "1")]) }
    }

    func pause() {
        graceUntil = Date().addingTimeInterval(3)
        enqueue("pause") { [self] in try await transport("Pause") }
    }

    func seek(to seconds: TimeInterval) {
        // Debounced: scrubbing produces bursts, the renderer only needs the last.
        seekGeneration += 1
        let generation = seekGeneration
        seekTask?.cancel()
        lastPosition = seconds
        expectedPosition = seconds
        noteStartRequested("seek to \(Int(seconds))s")
        graceUntil = Date().addingTimeInterval(4)
        seekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            self.enqueue("seek") { [self] in
                guard generation == seekGeneration else { return }
                try await seekNow(to: seconds)
                graceUntil = Date().addingTimeInterval(3)
            }
        }
    }

    func setNext(_ track: Track?) {
        guard supportsSetNext else {
            // Still warm up any transcode so the explicit load at the end
            // of this track doesn't wait for it.
            if let track { warmUp(track) }
            return
        }
        guard track?.id != armedNextID || track == nil else { return }
        armGeneration += 1
        let generation = armGeneration
        armTask?.cancel()
        armedNextID = track?.id
        nextPath = nil
        guard let track else { return }

        // Preparation (possibly a transcode) runs outside the command chain so
        // it never delays play/pause; only the SOAP call is serialized.
        armTask = Task { [weak self] in
            guard let self else { return }
            guard let item = try? await self.prepareItem(track),
                  !Task.isCancelled, generation == self.armGeneration else { return }
            self.enqueue("arm next") { [self] in
                guard generation == armGeneration else { return }
                do {
                    try await transport("SetNextAVTransportURI", [
                        ("NextURI", item.url.absoluteString),
                        ("NextURIMetaData", item.metadata),
                    ])
                    nextPath = item.url.path
                } catch is UPnPError {
                    // The renderer refused it (many — Linkplay included —
                    // don't implement SetNext). Fall back to loading each
                    // track when the previous one ends.
                    supportsSetNext = false
                    armedNextID = nil
                    print("[DLNA] \(renderer.friendlyName) has no SetNextAVTransportURI; loading tracks individually")
                }
            }
        }
    }

    func setVolume(_ volume: Float) {
        guard let url = renderer.renderingControlURL else { return }
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            let level = String(Int((max(0, min(1, volume)) * 100).rounded()))
            self.enqueue("volume") { [self] in
                try await soap.call("SetVolume", service: UPnPRendererDescription.renderingControlType, url: url,
                                    [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", level)])
            }
        }
    }

    // MARK: Polling

    private func poll() async {
        guard !isClosed else { return }
        do {
            let position = try await transport("GetPositionInfo")
            let info = try await transport("GetTransportInfo")
            firstFailure = nil
            handle(state: info["CurrentTransportState"] ?? "", position: position)
        } catch is UPnPError {
            // The device answered with an error — it's alive.
            firstFailure = nil
        } catch {
            noteUnreachable()
        }
    }

    private func handle(state: String, position: [String: String]) {
        guard let engine, !isClosed else { return }
        let relTime = DIDLLite.parseTime(position["RelTime"])
        let trackPath = position["TrackURI"].flatMap(URL.init(string:))?.path

        // Gapless advance: the renderer is now playing what we pre-armed.
        if let nextPath, let trackPath, trackPath == nextPath, trackPath != currentPath {
            currentPath = nextPath
            self.nextPath = nil
            armedNextID = nil
            lastPosition = relTime ?? 0
            engine.remoteDidAdvance()
            return
        }

        if state != lastLoggedState {
            let since = startRequestedAt.map { String(format: " (+%.2fs since start request)", Date().timeIntervalSince($0)) } ?? ""
            castLog.notice("state \(state, privacy: .public) at \(relTime ?? -1, privacy: .public)s\(since, privacy: .public)")
            lastLoggedState = state
        }

        let inGrace = Date() < graceUntil
        switch state {
        case "PLAYING":
            if let relTime { lastPosition = relTime }
            // A PLAYING report for the media we asked for, near where we
            // asked, is definitive even inside the grace window: it's what
            // starts the seek-bar clock. Anything else is stale.
            let isOurMedia = currentPath == nil || trackPath == nil || trackPath == currentPath
            // Only for a while: if the device was moved from its own app
            // meanwhile, its position wins.
            let expectationLive = startRequestedAt.map { Date().timeIntervalSince($0) < 15 } ?? false
            let isWhereExpected = !expectationLive || expectedPosition.map { expected in
                relTime.map { $0 >= expected - 2 && $0 <= expected + 6 } ?? true
            } ?? true
            if isOurMedia, isWhereExpected, currentPath != nil, !inGrace || engine.isPlaying {
                if engine.isAwaitingRemoteStart, let started = startRequestedAt {
                    castLog.notice("audible after \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s")
                }
                expectedPosition = nil
                engine.remoteDidReport(position: relTime, isPlaying: true)
            }
        case "PAUSED_PLAYBACK":
            if !inGrace { engine.remoteDidReport(position: relTime, isPlaying: false) }
        case "STOPPED", "NO_MEDIA_PRESENT":
            guard !inGrace, engine.isPlaying else { return }
            let duration = engine.duration ?? 0
            if duration > 0, lastPosition >= duration - 3 {
                lastPosition = 0
                engine.remoteDidReachEnd()
            } else {
                // Stopped from the speaker's own controls.
                engine.remoteDidReport(position: nil, isPlaying: false)
            }
        default:
            // TRANSITIONING and vendor states: wait for something definite.
            break
        }
    }

    private func noteUnreachable() {
        let now = Date()
        guard let first = firstFailure else {
            firstFailure = now
            return
        }
        if now.timeIntervalSince(first) >= Self.lostConnectionAfter, !isClosed {
            isClosed = true
            pollTask?.cancel()
            onConnectionLost?("Lost connection to \(renderer.friendlyName)")
        }
    }

    // MARK: Helpers

    private func noteStartRequested(_ what: String) {
        startRequestedAt = Date()
        castLog.notice("request: \(what, privacy: .public)")
    }

    /// Polls transport state until the device reports PLAYING (or times out).
    private func waitUntilPlaying(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled, !isClosed {
            if let info = try? await transport("GetTransportInfo"),
               info["CurrentTransportState"] == "PLAYING" { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private var isNearEnd: Bool {
        guard let engine, engine.isPlaying, let duration = engine.duration, duration > 0 else { return false }
        return duration - engine.currentTime < 3
    }

    private func warmUp(_ track: Track) {
        let plan = StreamPlanner.plan(for: track, capabilities: capabilities, quality: quality)
        guard case .transcode = plan else { return }
        let preparer = self.preparer
        Task { _ = try? await preparer.file(for: track, plan: plan) }
    }

    private func enqueue(_ name: String, _ operation: @escaping @MainActor () async throws -> Void) {
        let previous = commandTail
        commandTail = Task { [weak self] in
            await previous?.value
            guard let self, !self.isClosed, !Task.isCancelled else { return }
            do {
                try await operation()
            } catch is CancellationError {
            } catch {
                print("[DLNA] \(name) failed on \(self.renderer.friendlyName): \(error.localizedDescription)")
                if !(error is UPnPError), !(error is StreamPreparationError) {
                    self.noteUnreachable()
                }
            }
        }
    }

    @discardableResult
    private func transport(_ action: String, _ arguments: [(String, String)] = []) async throws -> [String: String] {
        let started = Date()
        do {
            let result = try await soap.call(action, service: UPnPRendererDescription.avTransportType,
                                             url: renderer.avTransportURL, [("InstanceID", "0")] + arguments)
            logCommand(action, started, outcome: "ok")
            return result
        } catch {
            logCommand(action, started, outcome: "failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func logCommand(_ action: String, _ started: Date, outcome: String) {
        // Polls are frequent and uninteresting unless slow.
        let elapsed = Date().timeIntervalSince(started)
        guard !action.hasPrefix("Get") || elapsed > 0.5 else { return }
        castLog.notice("\(action, privacy: .public) \(outcome, privacy: .public) in \(Int(elapsed * 1000), privacy: .public) ms")
    }

    private func seekNow(to seconds: TimeInterval) async throws {
        try await transport("Seek", [("Unit", "REL_TIME"), ("Target", DIDLLite.formatTime(seconds))])
    }

    private struct PreparedItem {
        let url: URL
        let metadata: String
    }

    private struct StreamPreparationError: Error {}

    /// Registers `track` (transcoded if the plan says so) and its artwork
    /// with the server. Every call mints fresh tokens, so arming the same
    /// track again (repeat-one) still gives the renderer a distinct URI.
    private func prepareItem(_ track: Track) async throws -> PreparedItem {
        let plan = StreamPlanner.plan(for: track, capabilities: capabilities, quality: quality)
        let fileURL: URL
        if case .transcode = plan {
            onStatusChange?("Preparing \(track.title)…")
            do {
                fileURL = try await preparer.file(for: track, plan: plan)
            } catch {
                onStatusChange?(nil)
                print("[DLNA] Transcode failed for \(track.title): \(error)")
                throw StreamPreparationError()
            }
            onStatusChange?(nil)
        } else {
            fileURL = track.url
        }

        let ext: String
        let rate: Double?
        let bits: Int?
        switch plan {
        case .original:
            ext = track.url.pathExtension.isEmpty ? "audio" : track.url.pathExtension.lowercased()
            rate = track.sampleRate
            bits = track.bitDepth
        case let .transcode(container, sampleRate, bitDepth):
            ext = container.rawValue
            rate = sampleRate
            bits = bitDepth
        }

        let audioPath = server.register(
            MediaResource(body: .file(fileURL), mimeType: plan.mimeType, isAudio: true),
            fileExtension: ext
        )
        var artworkURL: URL?
        if let art = track.artwork, !art.isEmpty {
            let (mime, artExt) = Self.imageType(art)
            let artPath = server.register(MediaResource(body: .data(art), mimeType: mime, isAudio: false),
                                          fileExtension: artExt)
            artworkURL = URL(string: artPath, relativeTo: baseURL)?.absoluteURL
        }
        guard let url = URL(string: audioPath, relativeTo: baseURL)?.absoluteURL else {
            throw StreamPreparationError()
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
        let resource = DIDLLite.Resource(url: url, mimeType: plan.mimeType, size: size,
                                         duration: track.duration, sampleRate: rate, bitDepth: bits,
                                         channels: nil)
        return PreparedItem(url: url, metadata: DIDLLite.metadata(for: track, resource: resource, artworkURL: artworkURL))
    }

    static func imageType(_ data: Data) -> (mime: String, ext: String) {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("image/png", "png") }
        return ("image/jpeg", "jpg")
    }
}
