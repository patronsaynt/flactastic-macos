@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import os

/// One streaming request: bytes are handed over as they arrive, and the
/// task can be paused (a preload nobody reads) or cancelled the moment it's
/// superseded, which ends the server's work on it too (§9.2).
final class StreamTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Requests started and not yet ended or cancelled, across the app.
    static let inFlight = OSAllocatedUnfairLock(initialState: 0)
    private let live = OSAllocatedUnfairLock(initialState: true)
    private func ended() { if live.withLock({ let was = $0; $0 = false; return was }) { Self.inFlight.withLock { $0 -= 1 } } }

    private let onResponse: (HTTPURLResponse) -> Void
    private let onData: (Data) -> Void
    private let onEnd: (Error?) -> Void
    private let client: ServerClient
    private var task: URLSessionDataTask?
    private var failed: HTTPURLResponse?
    private var errorBody = Data()

    init(_ client: ServerClient, _ request: URLRequest, onResponse: @escaping (HTTPURLResponse) -> Void,
         onData: @escaping (Data) -> Void, onEnd: @escaping (Error?) -> Void) {
        self.client = client
        self.onResponse = onResponse
        self.onData = onData
        self.onEnd = onEnd
        super.init()
        let task = client.session.dataTask(with: request)
        task.delegate = self
        self.task = task
        PlaybackTrace.mark("request")
        Self.inFlight.withLock { $0 += 1 }
        task.resume()
    }

    func cancel() { ended(); task?.cancel() }
    func suspend() { task?.suspend() }
    func resume() { task?.resume() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async
        -> URLSession.ResponseDisposition {
        PlaybackTrace.mark("headers")
        guard let http = response as? HTTPURLResponse else { return .cancel }
        if (200..<300).contains(http.statusCode) { onResponse(http) } else { failed = http }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if failed != nil { errorBody.append(data.prefix(65_536 - errorBody.count)) } else { onData(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        ended()
        if let failed {
            onEnd(Self.error(failed, errorBody))
        } else {
            onEnd(error.map(client.mapTransport))
        }
    }

    private static func error(_ http: HTTPURLResponse, _ body: Data) -> Error {
        do { try ServerClient.check(http, body: body); return ServerError.badResponse } catch { return error }
    }
}

/// An original being downloaded (§9.1) into a sparse cache file, read by Core
/// Audio through a callback. Bytes already here are read from disk; missing
/// ones move the download to them. It reads ahead as fast as the link allows,
/// up to `cap`, and keeps everything until it's dropped, so rewinds and
/// repeat seeks stay local.
///
/// The download is a run of bounded ranges, one at a time, each about a
/// quarter second of link time. Over one HTTP/2 connection, bytes already
/// sent can't be recalled, so a cancel leaves at most that much ahead of the
/// next response.
final class RemoteFile: @unchecked Sendable {
    static let cap: Int64 = 200 << 20
    /// Waiting longer than this for bytes is a stall (Auto quality reacts).
    static let stallSeconds: TimeInterval = 2
    /// Stalls so far, across the app (for tests and the trace).
    static let stalls = OSAllocatedUnfairLock(initialState: 0)

    private final class Window {
        var start: Int64
        var end: Int64
        var pos: Int64
        var task: StreamTask?
        let began = Date()
        init(_ start: Int64, _ end: Int64) { self.start = start; self.end = end; pos = start }
    }

    let size: Int64
    let file: URL
    private let client: ServerClient
    private let path: String
    private let fd: Int32
    private let condition = NSCondition()
    private var have = IndexSet()
    private var windows: [Window] = []
    private var windowSize: Int64 = 512 << 10
    private var etag: String?
    private var failure: Error?
    /// A preload stops reading here until the track plays.
    private var readAheadLimit: Int64?
    private(set) var lastRead: Int64 = 0
    /// Each source reading this file gets a number; the newest owns the
    /// download, and an older one (a decode pass replaced by a seek) gives up
    /// rather than pulling the download back to its bytes.
    private var readers = 0
    private var newestReader = 0

    func newReader() -> Int { condition.withLock { readers += 1; return readers } }
    var stallThrows = false
    private var stallNow = false
    private let onSpeed: @Sendable (Double) -> Void

    init(client: ServerClient, trackID: UUID, size: Int64, file: URL, readAheadLimit: Int64? = nil,
         onSpeed: @escaping @Sendable (Double) -> Void = { _ in }) throws {
        self.client = client
        // Playback goes through /stream (§9.2: the original there is /file
        // with the same Range semantics), so the server counts it as a
        // stream; /file is for downloads.
        self.path = "v2/tracks/\(trackID.uuidString)/stream"
        self.size = size
        self.file = file
        self.readAheadLimit = readAheadLimit
        self.onSpeed = onSpeed
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(file.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0, ftruncate(fd, size) == 0 else { throw ServerError.badResponse }
        condition.withLock { fetch(from: 0) }
    }

    deinit {
        windows.forEach { $0.task?.cancel() }
        close(fd)
        try? FileManager.default.removeItem(at: file)
    }

    func drop() { condition.withLock { stop() } }

    /// Playback ran dry on this file: with Auto, the waiting read gives up
    /// so the track reopens at a quality the link carries.
    func stalled() {
        condition.withLock {
            guard stallThrows else { return }
            stallNow = true
            condition.broadcast()
        }
    }

    private func stop() {
        windows.forEach { $0.task?.cancel() }
        windows = []
    }

    /// The track is playing now: read ahead without a preload's limit.
    func promote() {
        condition.withLock {
            readAheadLimit = nil
            if windows.isEmpty, let gap = nextGap(after: lastRead) { fetch(from: gap) }
        }
    }

    /// Contiguous bytes here from the last read onwards.
    var bufferedAhead: Int64 {
        condition.withLock {
            guard let r = have.rangeView.first(where: { $0.contains(Int(lastRead)) }) else { return 0 }
            return Int64(r.upperBound) - lastRead
        }
    }

    var isComplete: Bool { condition.withLock { have.count == Int(size) } }

    /// Whether every byte in `range` is here.
    func has(_ range: Range<Int64>) -> Bool {
        condition.withLock { range.isEmpty || have.contains(integersIn: Int(range.lowerBound)..<Int(range.upperBound)) }
    }

    /// Core Audio's read: blocks until the bytes are here. `reader` 0 is
    /// a one-off read outside any source.
    func read(into buffer: UnsafeMutableRawPointer, at offset: Int64, count: Int, reader: Int = 0) throws -> Int {
        guard offset < size else { return 0 }
        let end = min(size, offset + Int64(count))
        condition.lock()
        defer { condition.unlock() }
        if reader != 0 {
            if reader < newestReader { throw CancellationError() }
            newestReader = reader
        }
        lastRead = offset
        var waited = Date(), haveThen = have.count
        while let gap = nextGap(after: offset), gap < end {
            if reader != 0, reader < newestReader { throw CancellationError() }
            if let failure { self.failure = nil; throw failure }
            if stallNow, let w = windows.first {
                stallNow = false
                Self.stalls.withLock { $0 += 1 }
                let seconds = Date().timeIntervalSince(w.began)
                if seconds > 0.5 { onSpeed(Double(w.pos - w.start) / seconds) }
                throw ServerError.unreachable("Stalled")
            }
            // Move the download unless it's about to reach these bytes:
            // within 128 KB of where it's writing (about 50 ms at 20 Mbit/s).
            if let at = windows.first?.pos, gap >= at, gap - at < 128 << 10 {} else {
                fetch(from: gap); waited = Date(); haveThen = have.count
            }
            if !condition.wait(until: Date() + 0.25) {
                let stalled = Date().timeIntervalSince(waited)
                if stallThrows, stalled > Self.stallSeconds {
                    Self.stalls.withLock { $0 += 1 }
                    onSpeed(Double(have.count - haveThen) / stalled) // what the link managed meanwhile
                    throw ServerError.unreachable("Stalled")
                }
                if stalled > 30 { throw ServerError.unreachable("Stalled") }
            }
        }
        stallNow = false
        return pread(fd, buffer, Int(end - offset), off_t(offset))
    }

    private func nextGap(after offset: Int64) -> Int64? {
        guard offset < size else { return nil }
        let missing = IndexSet(integersIn: Int(offset)..<Int(size)).subtracting(have)
        return missing.first.map(Int64.init)
    }

    /// Restarts the download at `offset`.
    private func fetch(from offset: Int64) {
        stop()
        request(from: offset, force: true)
    }

    /// Asks for the next window from `offset` if anything there is missing:
    /// always for a read, otherwise only while read-ahead allows.
    private func request(from offset: Int64, force: Bool = false) {
        guard force || Int64(have.count) < min(readAheadLimit ?? Self.cap, size),
              let start = nextGap(after: offset) ?? nextGap(after: 0) else { return }
        let window = Window(start, min(size, start + windowSize))
        var request = client.request("GET", path, query: [URLQueryItem(name: "quality", value: "original")], timeout: 30)
        request.setValue("bytes=\(window.start)-\(window.end - 1)", forHTTPHeaderField: "Range")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-Range") }
        window.task = StreamTask(client, request, onResponse: { [weak self] http in
            self?.condition.withLock {
                guard let self else { return }
                if http.statusCode == 200 {
                    // The file changed (or ranges were ignored): all of it, from 0.
                    if self.etag != nil { self.have = IndexSet() }
                    for other in self.windows where other !== window { other.task?.cancel() }
                    self.windows = [window]
                    window.start = 0; window.pos = 0; window.end = self.size
                }
                self.etag = http.value(forHTTPHeaderField: "ETag")
            }
        }, onData: { [weak self] data in
            guard let self else { return }
            self.condition.withLock {
                guard self.windows.contains(where: { $0 === window }) else { return }
                _ = data.withUnsafeBytes { pwrite(self.fd, $0.baseAddress, data.count, off_t(window.pos)) }
                self.have.insert(integersIn: Int(window.pos)..<Int(window.pos) + data.count)
                window.pos += Int64(data.count)
                self.condition.broadcast()
            }
        }, onEnd: { [weak self] error in
            guard let self else { return }
            self.condition.withLock {
                guard let i = self.windows.firstIndex(where: { $0 === window }) else { return }
                self.windows.remove(at: i)
                let seconds = Date().timeIntervalSince(window.began)
                let bytes = window.pos - window.start
                if error == nil, bytes >= 128 << 10, seconds > 0.005 {
                    let rate = Double(bytes) / seconds
                    self.onSpeed(rate)
                    // About a quarter second of this link per window.
                    self.windowSize = min(16 << 20, max(256 << 10, Int64(rate / 4)))
                }
                if let error, (error as? CancellationError) == nil {
                    if let e = error as? ServerError, case .api = e { self.failure = error; self.condition.broadcast(); return }
                    // A stall or a dropped connection: carry on from the last byte.
                    let resume = window.pos
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.condition.withLock { if self?.windows.isEmpty == true { self?.fetch(from: resume) } }
                    }
                } else if self.windows.isEmpty {
                    self.request(from: window.end)
                }
                self.condition.broadcast()
            }
        })
        windows.append(window)
    }
}

/// What Core Audio reads: the remote file, or for a FLAC jump, its header
/// followed by the frames from byte `tail`.
final class RemoteView: @unchecked Sendable {
    let file: RemoteFile
    let prefix: Int64
    let tail: Int64
    let reader: Int
    /// A read failed (a stall, a dropped link). Core Audio may report that
    /// as a short read rather than an error, which would end the track.
    var failed = false

    init(_ file: RemoteFile, reader: Int, prefix: Int64 = 0, tail: Int64 = 0) {
        self.file = file
        self.reader = reader
        self.prefix = prefix
        self.tail = tail
    }

    var size: Int64 { prefix + file.size - tail }

    func read(into buffer: UnsafeMutableRawPointer, at offset: Int64, count: Int) throws -> Int {
        var done = 0
        while done < count, offset + Int64(done) < size {
            let v = offset + Int64(done)
            let (at, room) = v < prefix ? (v, Int(prefix - v)) : (tail + v - prefix, count - done)
            let n = try file.read(into: buffer + done, at: at, count: min(count - done, room), reader: reader)
            if n <= 0 { break }
            done += n
        }
        return done
    }
}

/// A FLAC's layout, for seeking one without a usable seek table: estimate
/// the byte from the average rate, find the next frame header there and read
/// its sample number (§9.1 leaves seeking to the client).
struct FLACLayout {
    let headerEnd: Int64
    let minBlock: Int64
    let totalFrames: Int64
    let seekPoints: Int

    static func read(_ file: RemoteFile, reader: Int) throws -> FLACLayout? {
        var head = [UInt8](repeating: 0, count: 42)
        guard try file.read(into: &head, at: 0, count: 42, reader: reader) == 42, head[0...3] == [0x66, 0x4C, 0x61, 0x43] else { return nil }
        let minBlock = Int64(head[8]) << 8 | Int64(head[9])
        let total = (Int64(head[21] & 0x0F) << 32) | Int64(head[22]) << 24 | Int64(head[23]) << 16 | Int64(head[24]) << 8 | Int64(head[25])
        var at: Int64 = 4, points = 0
        while true {
            var block = [UInt8](repeating: 0, count: 4)
            guard try file.read(into: &block, at: at, count: 4, reader: reader) == 4 else { return nil }
            let length = Int64(block[1]) << 16 | Int64(block[2]) << 8 | Int64(block[3])
            if block[0] & 0x7F == 3 { points = Int(length / 18) }
            at += 4 + length
            if block[0] & 0x80 != 0 { break }
        }
        return FLACLayout(headerEnd: at, minBlock: max(minBlock, 1), totalFrames: total, seekPoints: points)
    }

    /// Core Audio seeks well with a real seek table; without one it reads
    /// forward from the start, which waits for the download.
    var needsJumps: Bool { seekPoints < 2 && totalFrames > 0 }

    /// The frame starting at or before `target`, near it: (byte, its first sample).
    func locate(_ target: Int64, in file: RemoteFile, reader: Int) throws -> (Int64, Int64) {
        let perFrame = Double(file.size - headerEnd) / Double(totalFrames)
        // A few blocks early, so the first frame found is usually just before.
        var guess = headerEnd + Int64(Double(max(0, target - minBlock * 3)) * perFrame)
        var best: (Int64, Int64) = (headerEnd, 0)
        for _ in 0..<8 {
            guard let (at, sample) = try nextFrame(from: max(headerEnd, guess), in: file, reader: reader) else { break }
            if sample > target {
                guess = at - Int64(Double(sample - target + minBlock * 2) * perFrame)
                continue
            }
            if sample >= best.1 { best = (at, sample) }
            if target - sample < minBlock * 8 { break }
            guess = at + Int64(Double(target - sample) * perFrame * 0.98)
        }
        return best
    }

    /// The first valid frame header at or after `offset`.
    private func nextFrame(from offset: Int64, in file: RemoteFile, reader: Int, window size: Int = 32 << 10) throws -> (Int64, Int64)? {
        let window = Int(min(Int64(size), file.size - offset))
        guard window > 16 else { return nil }
        var b = [UInt8](repeating: 0, count: window)
        let n = try file.read(into: &b, at: offset, count: window, reader: reader)
        var i = 0
        while i + 16 < n {
            defer { i += 1 }
            guard b[i] == 0xFF, b[i + 1] & 0xFE == 0xF8, b[i + 2] >> 4 != 0, b[i + 2] & 0x0F != 0x0F,
                  b[i + 3] >> 4 < 11, b[i + 3] & 0x01 == 0 else { continue }
            // The coded frame or sample number (UTF-8 style, up to 7 bytes).
            let lead = b[i + 4]
            let extra = lead < 0x80 ? 0 : lead < 0xE0 ? 1 : lead < 0xF0 ? 2 : lead < 0xF8 ? 3 : lead < 0xFC ? 4 : lead < 0xFE ? 5 : 6
            guard lead & 0xC0 != 0x80 else { continue }
            var number = Int64(extra == 0 ? lead : lead & (0x3F >> extra))
            var ok = true
            for k in 0..<extra {
                let c = b[i + 5 + k]
                if c & 0xC0 != 0x80 { ok = false; break }
                number = number << 6 | Int64(c & 0x3F)
            }
            guard ok else { continue }
            var length = 5 + extra
            switch b[i + 2] >> 4 { case 6: length += 1; case 7: length += 2; default: break }
            switch b[i + 2] & 0x0F { case 12: length += 1; case 13, 14: length += 2; default: break }
            guard i + length < n, Self.crc8(b[i..<(i + length)]) == b[i + length] else { continue }
            let sample = b[i + 1] == 0xF8 ? number * minBlock : number
            guard sample < totalFrames else { continue }
            return (offset + Int64(i), sample)
        }
        // No header in a small window (an unusually large frame): look wider.
        return size < 256 << 10 && window == size ? try nextFrame(from: offset, in: file, reader: reader, window: size * 4) : nil
    }

    static func crc8<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }
}

/// An original read by Core Audio from a `RemoteFile`. The file's own tables
/// (FLAC seek table, Xing or VBRI, the M4A sample tables wherever `moov` is)
/// decide which bytes a seek needs; a FLAC without a seek table jumps by
/// estimate (`FLACLayout`).
final class RemoteAudioSource: PCMSource, @unchecked Sendable {
    var playbackSource: PlaybackSource? { .streaming }
    let remote: RemoteFile
    private let hint: AudioFileTypeID
    private let flac: FLACLayout?
    private var view: RemoteView
    /// The track's frame at the view's first frame (non-zero after a FLAC jump).
    private var base: Int64 = 0
    private var audioFile: AudioFileID?
    private var ext: ExtAudioFileRef?
    let processingFormat: AVAudioFormat
    let length: AVAudioFramePosition

    init(_ remote: RemoteFile, format: AudioFileFormat) throws {
        self.remote = remote
        hint = switch format {
        case .flac: kAudioFileFLACType
        case .mp3: kAudioFileMP3Type
        case .wav: kAudioFileWAVEType
        case .aiff: kAudioFileAIFFType
        case .alac, .aac: kAudioFileM4AType
        }
        let reader = remote.newReader()
        flac = format == .flac ? try FLACLayout.read(remote, reader: reader).flatMap { $0.needsJumps ? $0 : nil } : nil
        view = RemoteView(remote, reader: reader)
        let (af, ext) = try Self.open(view, hint)
        audioFile = af
        self.ext = ext
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &size, &asbd)
        guard let out = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame) else {
            throw ServerError.badResponse
        }
        processingFormat = out
        Self.setClient(ext, out)
        var frames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileLengthFrames, &size, &frames)
        length = frames
    }

    private static func open(_ view: RemoteView, _ hint: AudioFileTypeID) throws -> (AudioFileID, ExtAudioFileRef) {
        var af: AudioFileID?
        var status = AudioFileOpenWithCallbacks(Unmanaged.passUnretained(view).toOpaque(), remoteRead, nil,
                                                remoteSize, nil, hint, &af)
        var ext: ExtAudioFileRef?
        if status == noErr, let af { status = ExtAudioFileWrapAudioFileID(af, false, &ext) }
        guard status == noErr, let af, let ext else {
            if let af { AudioFileClose(af) }
            throw ServerError.badResponse
        }
        return (af, ext)
    }

    private static func setClient(_ ext: ExtAudioFileRef, _ format: AVAudioFormat) {
        ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), format.streamDescription)
    }

    private func close() {
        if let ext { ExtAudioFileDispose(ext) }
        if let audioFile { AudioFileClose(audioFile) }
        ext = nil
        audioFile = nil
    }

    deinit { close() }

    /// Reads through `view` from now on, its first frame being `base`.
    private func reopen(_ view: RemoteView, base: Int64) throws {
        close()
        let (af, ext) = try Self.open(view, hint)
        Self.setClient(ext, processingFormat)
        self.view = view
        self.base = base
        audioFile = af
        self.ext = ext
    }

    var framePosition: AVAudioFramePosition {
        get { var f: Int64 = 0; if let ext { ExtAudioFileTell(ext, &f) }; return base + f }
        set {
            do {
                if let flac {
                    let estimate = flac.headerEnd + Int64(Double(newValue) / Double(flac.totalFrames) * Double(remote.size - flac.headerEnd))
                    if !remote.has(flac.headerEnd..<min(remote.size, estimate + 1)) {
                        // Not here yet: jump near it rather than read up to it.
                        let (at, sample) = try flac.locate(newValue, in: remote, reader: view.reader)
                        try reopen(RemoteView(remote, reader: view.reader, prefix: flac.headerEnd, tail: at), base: sample)
                    } else if base != 0 {
                        try reopen(RemoteView(remote, reader: view.reader), base: 0)
                    }
                }
                if let ext { ExtAudioFileSeek(ext, max(0, newValue - base)) }
            } catch {
                close()
            }
        }
    }

    func read(into buffer: AVAudioPCMBuffer, frameCount frames: AVAudioFrameCount) throws {
        guard let ext else { throw ServerError.unreachable("Read failed") }
        buffer.frameLength = frames
        var count = frames
        let status = ExtAudioFileRead(ext, &count, buffer.mutableAudioBufferList)
        buffer.frameLength = status == noErr ? count : 0
        if status != noErr || view.failed { view.failed = false; throw ServerError.unreachable("Read failed") }
    }
}

private let remoteRead: AudioFile_ReadProc = { context, position, count, buffer, actual in
    let view = Unmanaged<RemoteView>.fromOpaque(context).takeUnretainedValue()
    do {
        actual.pointee = UInt32(max(0, try view.read(into: buffer, at: position, count: Int(count))))
        return noErr
    } catch {
        view.failed = true
        actual.pointee = 0
        return kAudioFileUnspecifiedError
    }
}

private let remoteSize: AudioFile_GetSizeProc = { context in
    Unmanaged<RemoteView>.fromOpaque(context).takeUnretainedValue().size
}
