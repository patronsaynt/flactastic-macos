@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

/// User cap on what's sent to network speakers. `.original` is bit-perfect;
/// the caps exist for congested Wi-Fi or renderers that stutter at high rates.
enum NetworkStreamQuality: String, CaseIterable, Identifiable, Sendable {
    case original
    case hiRes96
    case cd

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: "Original (bit-perfect)"
        case .hiRes96: "Up to 24-bit / 96 kHz"
        case .cd: "CD quality (16-bit / 44.1 kHz)"
        }
    }

    var maxSampleRate: Double? {
        switch self {
        case .original: nil
        case .hiRes96: 96_000
        case .cd: 44_100
        }
    }

    var maxBitDepth: Int? {
        switch self {
        case .original: nil
        case .hiRes96: 24
        case .cd: 16
        }
    }
}

/// What a renderer says it can play, from ConnectionManager `GetProtocolInfo`.
struct RendererCapabilities: Equatable, Sendable {
    /// Lower-cased MIME types from the sink list. Empty means unknown, in
    /// which case we assume the renderer can play what we send.
    let sinkMimeTypes: Set<String>

    static let unknown = RendererCapabilities(sinkMimeTypes: [])

    /// `http-get:*:audio/flac:*,http-get:*:audio/mpeg:DLNA.ORG_PN=MP3,…`
    static func parse(sink: String) -> RendererCapabilities {
        let types = sink.split(separator: ",").compactMap { entry -> String? in
            let fields = entry.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 3 else { return nil }
            let mime = fields[2].trimmingCharacters(in: .whitespaces).lowercased()
            return mime.isEmpty || mime == "*" ? nil : mime
        }
        return RendererCapabilities(sinkMimeTypes: Set(types))
    }

    func accepts(_ format: AudioFileFormat) -> Bool {
        guard !sinkMimeTypes.isEmpty else { return true }
        return StreamPlanner.mimeAliases(for: format).contains { sinkMimeTypes.contains($0) }
    }

    /// The spelling of `format`'s MIME type this renderer lists — some only
    /// match `protocolInfo` literally (e.g. `audio/m4a` but not `audio/mp4`).
    func mimeType(for format: AudioFileFormat) -> String {
        StreamPlanner.mimeAliases(for: format).first { sinkMimeTypes.contains($0) }
            ?? StreamPlanner.mimeType(for: format)
    }

    var acceptsFLAC: Bool { accepts(.flac) }
    var acceptsWAV: Bool { accepts(.wav) }
}

/// How one track will be delivered to a renderer.
enum StreamPlan: Equatable, Sendable {
    /// Serve the file's bytes untouched.
    case original(mimeType: String)
    /// Decode and re-encode, e.g. to honour a quality cap or because the
    /// renderer can't play the source format.
    case transcode(container: Container, sampleRate: Double, bitDepth: Int)

    enum Container: String, Sendable { case flac, wav }

    var mimeType: String {
        switch self {
        case .original(let mime): mime
        case .transcode(.flac, _, _): "audio/flac"
        case .transcode(.wav, _, _): "audio/wav"
        }
    }
}

enum StreamPlanner {

    static func mimeType(for format: AudioFileFormat) -> String {
        switch format {
        case .flac: "audio/flac"
        case .mp3: "audio/mpeg"
        case .wav: "audio/wav"
        case .aiff: "audio/aiff"
        case .alac, .aac: "audio/mp4"
        }
    }

    /// Preferred spelling first.
    static func mimeAliases(for format: AudioFileFormat) -> [String] {
        switch format {
        case .flac: ["audio/flac", "audio/x-flac"]
        case .mp3: ["audio/mpeg", "audio/mp3", "audio/x-mpeg"]
        case .wav: ["audio/wav", "audio/x-wav", "audio/wave", "audio/l16"]
        case .aiff: ["audio/aiff", "audio/x-aiff"]
        case .alac: ["audio/mp4", "audio/x-m4a", "audio/m4a"]
        case .aac: ["audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac", "audio/x-aac"]
        }
    }

    static func isLossless(_ format: AudioFileFormat) -> Bool {
        switch format {
        case .flac, .wav, .aiff, .alac: true
        case .mp3, .aac: false
        }
    }

    static func plan(for track: Track, capabilities: RendererCapabilities,
                     quality: NetworkStreamQuality) -> StreamPlan {
        let format = track.fileFormat
        let sourceRate = track.sampleRate ?? 44_100
        let sourceBits = track.bitDepth ?? 16

        // Caps only make sense for lossless sources; a lossy file is already
        // small and re-encoding it gains nothing.
        let exceedsCap = isLossless(format) && (
            (quality.maxSampleRate.map { sourceRate > $0 } ?? false)
                || (quality.maxBitDepth.map { sourceBits > $0 } ?? false)
        )

        if !exceedsCap, capabilities.accepts(format) {
            return .original(mimeType: capabilities.mimeType(for: format))
        }

        let rate = exceedsCap ? cappedRate(sourceRate, max: quality.maxSampleRate) : sourceRate
        let bits = min(sourceBits, quality.maxBitDepth ?? 24, 24)
        let container: StreamPlan.Container = capabilities.acceptsFLAC || !capabilities.acceptsWAV ? .flac : .wav
        return .transcode(container: container, sampleRate: rate, bitDepth: max(bits, 16))
    }

    /// Highest rate at or under `max` in the source's family (44.1k or 48k
    /// multiples), so downsampling is an integer ratio whenever possible.
    /// The CD cap is always 44.1 kHz, as its label promises.
    static func cappedRate(_ source: Double, max: Double?) -> Double {
        guard let max, source > max else { return source }
        if max <= 44_100 { return 44_100 }
        let family: Double = source.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100 : 48_000
        var rate = family
        while rate * 2 <= max { rate *= 2 }
        return rate
    }
}

// MARK: - Transcoding

/// Produces transcoded temp files for `StreamPlan.transcode`, de-duplicating
/// concurrent requests for the same track + plan so arming the next track
/// ahead of time never transcodes twice.
actor StreamPreparer {
    private var inFlight: [String: Task<URL, Error>] = [:]
    private let directory: URL

    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("FLACtastic-Cast", isDirectory: true)) {
        self.directory = directory
    }

    func file(for track: Track, plan: StreamPlan) async throws -> URL {
        guard case let .transcode(container, rate, bits) = plan else { return track.url }
        let key = "\(track.url.path)|\(container.rawValue)|\(Int(rate))|\(bits)"
        if let task = inFlight[key] { return try await task.value }

        let name = "\(abs(key.hashValue))-\(Int(rate))-\(bits).\(container.rawValue)"
        let output = directory.appendingPathComponent(name)
        let directory = self.directory
        let source = track.url
        let task = Task.detached(priority: .userInitiated) { () throws -> URL in
            if FileManager.default.fileExists(atPath: output.path) { return output }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let partial = output.appendingPathExtension("partial")
            try Transcoder.transcode(source: source, to: partial, container: container,
                                     sampleRate: rate, bitDepth: bits)
            try FileManager.default.moveItem(at: partial, to: output)
            return output
        }
        inFlight[key] = task
        do {
            let url = try await task.value
            return url
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    /// Deletes every transcoded file. Called when a session ends.
    func purge() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}

enum Transcoder {
    enum Failure: Error { case unreadable, encoderUnavailable(OSStatus), conversion }

    /// Decode `source`, resample with the mastering-quality converter if the
    /// rate changes, and encode to FLAC (or LPCM WAV) at `bitDepth`.
    static func transcode(source: URL, to destination: URL, container: StreamPlan.Container,
                          sampleRate: Double, bitDepth: Int) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let channels = input.processingFormat.channelCount
        guard let clientFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                               channels: channels, interleaved: false) else {
            throw Failure.conversion
        }

        var fileFormat = AudioStreamBasicDescription()
        let fileType: AudioFileTypeID
        switch container {
        case .flac:
            fileType = kAudioFileFLACType
            fileFormat.mFormatID = kAudioFormatFLAC
            fileFormat.mFormatFlags = switch bitDepth {
            case ...16: kAppleLosslessFormatFlag_16BitSourceData
            case 17...20: kAppleLosslessFormatFlag_20BitSourceData
            default: kAppleLosslessFormatFlag_24BitSourceData
            }
        case .wav:
            fileType = kAudioFileWAVEType
            let bytes = UInt32(bitDepth <= 16 ? 2 : 3)
            fileFormat.mFormatID = kAudioFormatLinearPCM
            fileFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            fileFormat.mBitsPerChannel = bytes * 8
            fileFormat.mBytesPerFrame = bytes * channels
            fileFormat.mBytesPerPacket = bytes * channels
            fileFormat.mFramesPerPacket = 1
        }
        fileFormat.mSampleRate = sampleRate
        fileFormat.mChannelsPerFrame = channels

        try? FileManager.default.removeItem(at: destination)
        var extFile: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(destination as CFURL, fileType, &fileFormat, nil,
                                               AudioFileFlags.eraseFile.rawValue, &extFile)
        guard status == noErr, let extFile else { throw Failure.encoderUnavailable(status) }
        defer { ExtAudioFileDispose(extFile) }

        var client = clientFormat.streamDescription.pointee
        status = ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else { throw Failure.encoderUnavailable(status) }

        let readFrames: AVAudioFrameCount = 16_384
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: readFrames) else {
            throw Failure.conversion
        }

        func write(_ buffer: AVAudioPCMBuffer) throws {
            guard buffer.frameLength > 0 else { return }
            let status = ExtAudioFileWrite(extFile, buffer.frameLength, buffer.audioBufferList)
            guard status == noErr else { throw Failure.encoderUnavailable(status) }
        }

        // Same rate: no resampler, just requantize/encode.
        if input.processingFormat.sampleRate == sampleRate {
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: readBuffer, frameCount: readFrames)
                if readBuffer.frameLength == 0 { break }
                try write(readBuffer)
            }
            return
        }

        guard let converter = AVAudioConverter(from: input.processingFormat, to: clientFormat) else {
            throw Failure.conversion
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        let ratio = sampleRate / input.processingFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(readFrames) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: outFrames) else {
            throw Failure.conversion
        }
        var inputDone = false
        var readError: Error?
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let result = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                // Reading at EOF throws, so stop before asking for more.
                if inputDone || input.framePosition >= input.length {
                    inputDone = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: readBuffer, frameCount: readFrames)
                } catch {
                    readError = error
                }
                if readBuffer.frameLength == 0 {
                    inputDone = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return readBuffer
            }
            if let readError { throw readError }
            if result == .error { throw conversionError ?? Failure.conversion }
            try write(outBuffer)
            if result == .endOfStream { break }
        }
    }
}
