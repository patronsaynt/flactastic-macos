@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import os

/// The user's streaming mode, stored on the server as `streamQuality` (§14).
enum StreamQuality: String, CaseIterable, Identifiable, Sendable {
    case auto, original, high, normal, low
    var id: String { rawValue }
    /// AAC-LC bitrate of each transcode (§9.2); 0 for the others.
    var kbps: Int {
        switch self {
        case .high: 256
        case .normal: 160
        case .low: 96
        case .auto, .original: 0
        }
    }
    var label: String {
        switch self {
        case .auto: "Automatic"
        case .original: "Original"
        case .high: "High (AAC 256 kbit/s)"
        case .normal: "Normal (AAC 160 kbit/s)"
        case .low: "Low (AAC 96 kbit/s)"
        }
    }
}

/// Opens server tracks for the engine (§9.1, §9.2). Thread-safe: the engine
/// calls it from its decode task. Holds the current track's download or
/// stream and one preload of the next; everything else is cancelled.
final class ServerStreamer: Sendable {
    struct TrackInfo: Sendable {
        let id: UUID
        let format: AudioFileFormat
        let fileSize: Int64
        let contentHash: String?
        let sampleRate: Double
        let bitrate: Int
        /// Exact for FLAC, WAV and AIFF (§7).
        let frames: Int64?
        var duration: Double? = nil

        /// The original's average rate, for Auto and read-ahead sizes.
        var bytesPerSecond: Double {
            if let duration, duration > 0 { return Double(fileSize) / duration }
            return Double(max(bitrate, 320)) * 125
        }
    }

    struct Config: Sendable {
        var client: ServerClient?
        var quality: StreamQuality = .original
        var transcoding = true
        /// Keyed by the track's standardized file path: queued copies of a
        /// track get fresh IDs (`withNewID`) but keep their URL.
        var tracks: [String: TrackInfo] = [:]
        /// Server IDs whose offline copy is installed and matches the server.
        var offline: Set<UUID> = []
        var cacheDirectory: URL?
    }

    private struct Held {
        var files: [UUID: RemoteFile] = [:]
        var streams: [UUID: ADTSStore] = [:]
        var current: UUID?
        var next: UUID?
        var preload: Task<Void, Never>?
    }

    let config = OSAllocatedUnfairLock(initialState: Config())
    private let held = OSAllocatedUnfairLock(initialState: Held())
    /// Recent download speed in bytes per second, nil until measured; drives `auto`.
    let throughput = OSAllocatedUnfairLock<Double?>(initialState: nil)

    /// A source for `track`, or nil when it isn't a server track or a
    /// verified offline copy should play instead (never transcoded).
    func open(_ track: Track, at seconds: TimeInterval) async throws -> (any PCMSource)? {
        let c = config.withLock { $0 }
        guard let client = c.client, let info = c.tracks[track.url.standardizedFileURL.path] else { return nil }
        if c.offline.contains(info.id), FileManager.default.fileExists(atPath: track.url.path) {
            return OfflineCopySource(try AVAudioFile(forReading: track.url, commonFormat: .pcmFormatFloat32, interleaved: false))
        }
        let auto = c.quality == .auto && c.transcoding
        let quality = c.transcoding ? pick(c.quality, info) : .original
        if quality != .original {
            // Busy (503): three more tries 250 ms apart, then the original.
            for attempt in 0...3 {
                do { return try await transcode(info, quality, at: seconds, client: client, stallThrows: auto) }
                catch ServerError.api(code: "transcodeUnavailable", _, _) where attempt < 3 {
                    try await Task.sleep(for: .milliseconds(250))
                } catch ServerError.api(code: "transcodeUnavailable", _, _) { break }
            }
        }
        guard let dir = c.cacheDirectory else { return nil }
        let file = try remoteFile(info, client: client, dir: dir, readAhead: nil)
        file.stallThrows = auto
        return try RemoteAudioSource(file, format: info.format)
    }

    /// Auto (§9.2): the original when the link carries 1.5 times its average
    /// rate, else the highest transcode under half of it. Per track; a stall
    /// lowers the measure, and the engine's reopen then picks again.
    func pick(_ mode: StreamQuality, _ info: TrackInfo) -> StreamQuality {
        guard mode == .auto else { return mode }
        guard let bytes = throughput.withLock({ $0 }) else { return .original }
        let bps = bytes * 8
        if bps > info.bytesPerSecond * 8 * 1.5 { return .original }
        return [StreamQuality.high, .normal].first { Double($0.kbps * 1000) < bps / 2 } ?? .low
    }

    /// The engine ran dry mid-track: the playing track's download stalled.
    func stalled() {
        let (file, stream) = held.withLock { h in (h.current.flatMap { h.files[$0] }, h.current.flatMap { h.streams[$0] }) }
        file?.stalled()
        stream?.stalled()
    }

    private func measured(_ bytesPerSecond: Double) {
        throughput.withLock { $0 = $0.map { $0 * 0.6 + bytesPerSecond * 0.4 } ?? bytesPerSecond }
    }

    private func remoteFile(_ info: TrackInfo, client: ServerClient, dir: URL, readAhead: Int64?) throws -> RemoteFile {
        if let file = held.withLock({ $0.files[info.id] }) {
            if readAhead == nil { file.promote() }
            return file
        }
        let file = try RemoteFile(client: client, trackID: info.id, size: info.fileSize,
                                  file: dir.appendingPathComponent("\(info.id.uuidString).part"),
                                  readAheadLimit: readAhead, onSpeed: { [weak self] in self?.measured($0) })
        held.withLock { $0.files[info.id] = file }
        return file
    }

    /// A transcode from `seconds`: from what's already received when it
    /// covers that point (no request), else a new stream at `?s=`.
    private func transcode(_ info: TrackInfo, _ quality: StreamQuality, at seconds: TimeInterval,
                           client: ServerClient, stallThrows: Bool) async throws -> ADTSStreamSource {
        if let store = held.withLock({ $0.streams[info.id] }), store.quality == quality, let reader = store.reader(at: seconds) {
            store.promote()
            store.stallThrows = stallThrows
            return ADTSStreamSource(store: store, reader: reader, duration: info.duration) { [weak self] s in
                try await self?.transcode(info, quality, at: s, client: client, stallThrows: stallThrows)
            }
        }
        // Superseded: end the old stream before asking for the new one.
        held.withLock { $0.streams.removeValue(forKey: info.id) }?.cancel()
        let store = try await ADTSStore.open(client: client, trackID: info.id, quality: quality, seconds: seconds,
                                             sourceRate: info.sampleRate, onSpeed: { [weak self] in self?.measured($0) })
        store.stallThrows = stallThrows
        held.withLock { h in
            h.streams[info.id]?.cancel()
            h.streams[info.id] = store
        }
        return ADTSStreamSource(store: store, reader: store.reader(at: seconds, received: false)!, duration: info.duration) { [weak self] s in
            try await self?.transcode(info, quality, at: s, client: client, stallThrows: stallThrows)
        }
    }

    /// Whether a download or stream of `id` is held (playing or preloaded).
    func holds(_ id: UUID) -> Bool { held.withLock { $0.files[id] != nil || $0.streams[id] != nil } }

    /// The engine's current and next tracks. Everything else is cancelled;
    /// the next one is preloaded once the current has ten seconds ahead.
    func upcoming(current: Track?, next: Track?) {
        let c = config.withLock { $0 }
        let cur = current.flatMap { c.tracks[$0.url.standardizedFileURL.path] }
        let nxt = next.flatMap { c.tracks[$0.url.standardizedFileURL.path] }
        let keep = Set([cur?.id, nxt?.id].compactMap { $0 })
        held.withLock { h in
            for (id, f) in h.files where !keep.contains(id) { f.drop() }
            for (id, s) in h.streams where !keep.contains(id) { s.cancel() }
            h.files = h.files.filter { keep.contains($0.key) }
            h.streams = h.streams.filter { keep.contains($0.key) }
            guard h.current != cur?.id || h.next != nxt?.id else { return }
            h.current = cur?.id
            h.next = nxt?.id
            h.preload?.cancel()
            h.preload = nil
            guard let cur, let nxt, let client = c.client, let dir = c.cacheDirectory,
                  !c.offline.contains(nxt.id) else { return }
            h.preload = Task.detached(priority: .utility) { [weak self] in
                await self?.preload(nxt, after: cur, client: client, dir: dir)
            }
        }
    }

    private func preload(_ next: TrackInfo, after current: TrackInfo, client: ServerClient, dir: URL) async {
        // Wait for the playing track to have ten seconds in hand.
        for _ in 0..<480 where !Task.isCancelled {
            let ahead: Double = held.withLock { h in
                if let f = h.files[current.id] { return f.isComplete ? .infinity : Double(f.bufferedAhead) / current.bytesPerSecond }
                if let s = h.streams[current.id] { return s.isFinished ? .infinity : s.bufferedSeconds }
                return 0
            }
            if ahead >= 10 { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        while !Task.isCancelled {
            let c = config.withLock { $0 }
            let quality = c.transcoding ? pick(c.quality, next) : .original
            do {
                if quality == .original {
                    let file = try remoteFile(next, client: client, dir: dir, readAhead: max(512 << 10, Int64(next.bytesPerSecond * 10)))
                    // Open it once, so whatever Core Audio needs to start (an
                    // M4A's moov at the end, say) is here before the skip.
                    _ = try RemoteAudioSource(file, format: next.format)
                } else {
                    let store = try await ADTSStore.open(client: client, trackID: next.id, quality: quality, seconds: 0,
                                                         sourceRate: next.sampleRate, pauseAfter: 10,
                                                         onSpeed: { [weak self] in self?.measured($0) })
                    guard !Task.isCancelled else { return store.cancel() }
                    held.withLock { $0.streams[next.id] = store }
                }
                return
            } catch ServerError.api(code: "transcodeUnavailable", _, _) {
                // Quietly, and again in five seconds.
                try? await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
        }
    }

    /// One ranged GET of the original (§9.1). `If-Range` turns a changed
    /// file into a full `200`, which the caller treats as a restart.
    static func fetch(_ client: ServerClient, _ id: UUID, _ range: Range<Int64>, _ etag: String?)
        async throws -> (Data, partial: Bool, etag: String?) {
        var r = client.request("GET", "v2/tracks/\(id.uuidString)/file")
        r.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-Range") }
        let (data, http) = try await client.data(for: r)
        return (data, http.statusCode == 206, http.value(forHTTPHeaderField: "ETag"))
    }
}

// MARK: - Transcodes: ADTS AAC, trimmed for gapless playback

/// A transcode's packets as they arrive (§9.2), kept for the track so a seek
/// inside them decodes locally. A preload stops reading after `pauseAfter`
/// seconds, which leaves the server's encoder idle until it plays.
final class ADTSStore: @unchecked Sendable {
    let quality: StreamQuality
    /// Where this stream starts in the track, in output frames.
    let start: AVAudioFramePosition
    let priming: Int64
    let frames: Int64?
    private let condition = NSCondition()
    private var packets: [Data] = []
    private var ended = false
    private var failure: Error?
    private var parser: AudioFileStreamID?
    fileprivate var inFormat: AVAudioFormat?
    private(set) var outFormat: AVAudioFormat?
    private var task: StreamTask?
    private var pauseAfterPackets: Int?
    private var paused = false
    /// Received this far ahead of the reader, stop reading for now: a cancel
    /// then leaves little in flight on the connection.
    private static let aheadSeconds = 30.0
    /// The furthest packet a reader has taken.
    private var readIndex = 0
    var stallThrows = false
    private var stallNow = false

    /// Playback ran dry on this stream: with Auto, the waiting read gives up.
    func stalled() {
        condition.withLock {
            guard stallThrows else { return }
            stallNow = true
            condition.broadcast()
        }
    }

    init(quality: StreamQuality = .normal, start: AVAudioFramePosition = 0, priming: Int, frames: Int?) {
        self.quality = quality
        self.start = start
        self.priming = Int64(max(0, priming))
        self.frames = frames.map(Int64.init)
        AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(), adtsPropertyProc, adtsPacketsProc,
                            kAudioFileAAC_ADTSType, &parser)
    }

    deinit {
        task?.cancel()
        if let parser { AudioFileStreamClose(parser) }
    }

    /// Requests the stream from `seconds` and returns once its format is known.
    static func open(client: ServerClient, trackID: UUID, quality: StreamQuality, seconds: TimeInterval,
                     sourceRate: Double, pauseAfter: Double? = nil,
                     onSpeed: @escaping @Sendable (Double) -> Void) async throws -> ADTSStore {
        let request = client.request("GET", "v2/tracks/\(trackID.uuidString)/stream", query: [
            URLQueryItem(name: "quality", value: quality.rawValue),
            URLQueryItem(name: "s", value: String(max(0, Int((seconds * sourceRate).rounded())))),
        ], timeout: 30)
        let box = OSAllocatedUnfairLock<ADTSStore?>(initialState: nil)
        // Measured every 256 KB, so the rate follows the link as it changes.
        let sample = OSAllocatedUnfairLock(initialState: (bytes: 0, since: Date()))
        // A decode pass replaced by a seek cancels its open, and the request,
        // even if the cancel lands before the request exists.
        let task = OSAllocatedUnfairLock<(stream: StreamTask?, cancelled: Bool)>(initialState: (nil, false))
        let store: ADTSStore = try await withTaskCancellationHandler { try await withCheckedThrowingContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Result<ADTSStore, Error>) -> Void = { result in
                if once.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(with: result) }
            }
            guard !task.withLock({ $0.cancelled }) else { return continuation.resume(throwing: CancellationError()) }
            let stream = StreamTask(client, request, onResponse: { http in
                let header = { (name: String) in http.value(forHTTPHeaderField: name).flatMap { Int($0) } }
                let rate = Double(header("FLACtastic-Sample-Rate") ?? Int(sourceRate))
                let store = ADTSStore(quality: quality, start: AVAudioFramePosition((seconds * rate).rounded()),
                                      priming: header("FLACtastic-Priming") ?? 0, frames: header("FLACtastic-Frames"))
                store.pauseAfterPackets = pauseAfter.map { Int($0 * rate / 1024) }
                box.withLock { $0 = store }
                finish(.success(store))
            }, onData: { data in
                let rate: Double? = sample.withLock { s in
                    s.bytes += data.count
                    guard s.bytes >= 256 << 10 else { return nil }
                    defer { s = (0, Date()) }
                    return Double(s.bytes) / max(0.005, Date().timeIntervalSince(s.since))
                }
                if let rate { onSpeed(rate) }
                box.withLock { $0 }?.feed(data)
            }, onEnd: { error in
                if let store = box.withLock({ $0 }) { store.finish(error) } else { finish(.failure(error ?? ServerError.badResponse)) }
            })
            if task.withLock({ $0.stream = stream; return $0.cancelled }) { stream.cancel() }
        } } onCancel: {
            task.withLock { $0.cancelled = true; return $0.stream }?.cancel()
        }
        store.task = task.withLock { $0.stream }
        if Task.isCancelled { store.cancel(); throw CancellationError() }
        _ = try await Task.detached { try store.waitForFormat() }.value
        return store
    }

    func cancel() { task?.cancel() }

    /// The track is playing now: read on past a preload's pause.
    func promote() {
        condition.withLock {
            pauseAfterPackets = nil
            if paused { paused = false; task?.resume() }
        }
    }

    var isFinished: Bool { condition.withLock { ended } }
    var bufferedSeconds: Double {
        condition.withLock { Double(packets.count - readIndex) * 1024 / (outFormat?.sampleRate ?? 44_100) }
    }

    func feed(_ data: Data) {
        guard let parser, !data.isEmpty else { return }
        let status = data.withUnsafeBytes { AudioFileStreamParseBytes(parser, UInt32(data.count), $0.baseAddress, []) }
        if status != noErr { finish(ServerError.badResponse) }
    }

    func finish(_ error: Error? = nil) {
        condition.withLock {
            ended = true
            if let error, (error as? CancellationError) == nil { failure = failure ?? error }
            condition.broadcast()
        }
    }

    fileprivate func gotFormat(_ asbd: AudioStreamBasicDescription) {
        var asbd = asbd
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame)
        else { return finish(ServerError.badResponse) }
        condition.withLock { inFormat = input; outFormat = output; condition.broadcast() }
    }

    fileprivate func gotPackets(_ bytes: UnsafeRawPointer, _ descriptions: UnsafeBufferPointer<AudioStreamPacketDescription>) {
        let new = descriptions.map { Data(bytes: bytes + Int($0.mStartOffset), count: Int($0.mDataByteSize)) }
        condition.withLock {
            packets += new
            let rate = outFormat?.sampleRate ?? 44_100
            let limit = pauseAfterPackets ?? readIndex + Int(Self.aheadSeconds * rate / 1024)
            if packets.count >= limit, !paused { paused = true; task?.suspend() }
            condition.broadcast()
        }
    }

    func waitForFormat() throws -> AVAudioFormat {
        condition.lock()
        defer { condition.unlock() }
        while outFormat == nil {
            if ended { throw failure ?? ServerError.badResponse }
            if !condition.wait(until: .now + 30) { throw ServerError.unreachable("Stream stalled") }
        }
        return outFormat!
    }

    /// Packet `i`, waiting for the network; nil at the end.
    fileprivate func packet(_ i: Int) throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        let began = Date()
        while i >= packets.count && !ended {
            if paused { paused = false; pauseAfterPackets = nil; task?.resume() }
            if stallNow {
                stallNow = false
                RemoteFile.stalls.withLock { $0 += 1 }
                throw ServerError.unreachable("Stalled")
            }
            if !condition.wait(until: .now + 0.25) {
                let waited = Date().timeIntervalSince(began)
                if (stallThrows && waited > RemoteFile.stallSeconds) || waited > 30 {
                    RemoteFile.stalls.withLock { $0 += 1 }
                    throw ServerError.unreachable("Stalled")
                }
            }
        }
        stallNow = false
        if i < packets.count {
            readIndex = max(readIndex, i)
            // Half the read-ahead used: carry on reading.
            if paused, pauseAfterPackets == nil, packets.count - readIndex < Int(Self.aheadSeconds / 2 * (outFormat?.sampleRate ?? 44_100) / 1024) {
                paused = false
                task?.resume()
            }
            return packets[i]
        }
        if let failure { throw failure }
        return nil
    }

    /// A reader from `seconds` into the track, when this stream covers it
    /// and, with `received`, has already received it (a seek in memory).
    func reader(at seconds: TimeInterval, received: Bool = true) -> ADTSDecoder? {
        guard let rate = condition.withLock({ outFormat?.sampleRate }) else { return nil }
        let offset = max(0, AVAudioFramePosition((seconds * rate).rounded()) - start)
        let packet = Int((priming + offset) / 1024)
        let have = !received || condition.withLock { ended || packet < packets.count }
        guard AVAudioFramePosition((seconds * rate).rounded()) >= start, have else { return nil }
        return ADTSDecoder(store: self, offset: offset)
    }
}

/// Decodes a server transcode (§9.2) from a store: drops `priming` frames
/// from the start of the decoded audio and stops after `frames` more (when
/// known), so a transcoded track plays exactly its own length. Starting
/// mid-store, it decodes one packet early and drops it, so the AAC overlap
/// is right from the first frame it hands over.
final class ADTSDecoder: @unchecked Sendable {
    let store: ADTSStore
    private var converter: AVAudioConverter?
    private var index: Int
    private var skip: Int64
    private var failure: Error?
    /// Frames handed over, counted from the store's start.
    private(set) var delivered: Int64

    init(store: ADTSStore, offset: Int64) {
        self.store = store
        let sample = store.priming + offset
        index = max(0, Int(sample / 1024) - 1)
        skip = sample - Int64(index) * 1024
        delivered = offset
    }

    /// A decoder with its own store, fed by hand.
    convenience init(priming: Int, frames: Int?) {
        self.init(store: ADTSStore(priming: priming, frames: frames), offset: 0)
    }

    func feed(_ data: Data) { store.feed(data) }
    func finish(_ error: Error? = nil) { store.finish(error) }

    @discardableResult
    func waitForFormat() throws -> AVAudioFormat {
        let format = try store.waitForFormat()
        if converter == nil, let input = store.inFormat { converter = AVAudioConverter(from: input, to: format) }
        return format
    }

    var outFormat: AVAudioFormat? { store.outFormat }

    /// Fills `buffer` with up to `count` trimmed frames; zero means the end.
    func read(into buffer: AVAudioPCMBuffer, frameCount count: AVAudioFrameCount) throws {
        buffer.frameLength = 0
        let format = try waitForFormat()
        guard let converter else { return }
        if let frames = store.frames, delivered >= frames { return }
        while buffer.frameLength == 0 {
            guard let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
            var error: NSError?
            let status = converter.convert(to: scratch, error: &error) { _, outStatus in
                guard let packet = self.nextPacket() else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return packet
            }
            if let failure { throw failure }
            if status == .error { throw error ?? ServerError.badResponse }
            take(scratch, into: buffer)
            if scratch.frameLength == 0 || status == .endOfStream { return }
        }
    }

    /// Copies what survives the trim from `scratch` into `out`.
    private func take(_ scratch: AVAudioPCMBuffer, into out: AVAudioPCMBuffer) {
        var start = Int64(0), n = Int64(scratch.frameLength)
        let drop = min(n, skip)
        if drop > 0 { skip -= drop; start = drop; n -= drop }
        if let frames = store.frames { n = min(n, frames - delivered) }
        guard n > 0, let src = scratch.floatChannelData, let dst = out.floatChannelData else { return }
        for ch in 0..<Int(scratch.format.channelCount) {
            (dst[ch] + Int(out.frameLength)).update(from: src[ch] + Int(start), count: Int(n))
        }
        out.frameLength += AVAudioFrameCount(n)
        delivered += n
    }

    /// The next few packets as one compressed buffer.
    private func nextPacket() -> AVAudioCompressedBuffer? {
        guard let inFormat = store.inFormat else { return nil }
        var batch: [Data] = []
        do {
            while batch.count < 16, let p = try store.packet(index) {
                batch.append(p)
                index += 1
                if batch.count >= 1, (try? store.packet(index)) == nil { break }
            }
        } catch {
            failure = error
            return nil
        }
        guard !batch.isEmpty else { return nil }
        let buffer = AVAudioCompressedBuffer(format: inFormat, packetCapacity: AVAudioPacketCount(batch.count),
                                             maximumPacketSize: batch.map(\.count).max() ?? 0)
        var offset = 0
        for (i, packet) in batch.enumerated() {
            packet.withUnsafeBytes { (buffer.data + offset).copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
            buffer.packetDescriptions![i] = AudioStreamPacketDescription(
                mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
            offset += packet.count
        }
        buffer.byteLength = UInt32(offset)
        buffer.packetCount = AVAudioPacketCount(batch.count)
        return buffer
    }
}

private let adtsPropertyProc: AudioFileStream_PropertyListenerProc = { context, stream, property, _ in
    guard property == kAudioFileStreamProperty_DataFormat else { return }
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioFileStreamGetProperty(stream, property, &size, &asbd) == noErr else { return }
    Unmanaged<ADTSStore>.fromOpaque(context).takeUnretainedValue().gotFormat(asbd)
}

private let adtsPacketsProc: AudioFileStream_PacketsProc = { context, _, count, bytes, descriptions in
    guard let descriptions, count > 0 else { return }
    Unmanaged<ADTSStore>.fromOpaque(context).takeUnretainedValue()
        .gotPackets(bytes, UnsafeBufferPointer(start: descriptions, count: Int(count)))
}

/// A transcoded stream as a `PCMSource`. A seek inside what's received
/// decodes locally; elsewhere it asks the streamer for a new stream at `s`.
final class ADTSStreamSource: PCMSource, @unchecked Sendable {
    var playbackSource: PlaybackSource? { .transcode(store.quality) }
    private var store: ADTSStore
    private var decoder: ADTSDecoder
    private let duration: TimeInterval?
    private let reopen: @Sendable (TimeInterval) async throws -> ADTSStreamSource?
    let processingFormat: AVAudioFormat

    init(store: ADTSStore, reader: ADTSDecoder, duration: TimeInterval?,
         reopen: @escaping @Sendable (TimeInterval) async throws -> ADTSStreamSource?) {
        self.store = store
        decoder = reader
        self.duration = duration
        self.reopen = reopen
        processingFormat = store.outFormat!
    }

    var length: AVAudioFramePosition {
        if let frames = store.frames { return store.start + frames }
        // Unknown length: an estimate a little long; a zero-frame read ends it.
        return AVAudioFramePosition(((duration ?? 0) + 1) * processingFormat.sampleRate)
    }

    var framePosition: AVAudioFramePosition {
        get { store.start + decoder.delivered }
        set {
            // The engine's frame and ours can differ by one in rounding.
            guard abs(newValue - framePosition) > 1 else { return }
            let seconds = Double(newValue) / processingFormat.sampleRate
            if let reader = store.reader(at: seconds) { decoder = reader; return }
            let box = OSAllocatedUnfairLock<ADTSStreamSource?>(initialState: nil)
            let semaphore = DispatchSemaphore(value: 0)
            let reopen = self.reopen
            Task.detached {
                let other = try? await reopen(seconds)
                box.withLock { $0 = other }
                semaphore.signal()
            }
            semaphore.wait()
            if let other = box.withLock({ $0 }) { store = other.store; decoder = other.decoder }
        }
    }

    func read(into buffer: AVAudioPCMBuffer, frameCount frames: AVAudioFrameCount) throws {
        try decoder.read(into: buffer, frameCount: frames)
    }
}
