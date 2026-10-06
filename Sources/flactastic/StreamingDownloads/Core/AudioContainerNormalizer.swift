@preconcurrency import AVFoundation
import Foundation

/// Turns a downloaded MP4-family file into an `.m4a` the library can index.
///
/// Why this exists: SoundCloud now serves its best streams as AAC, and
/// Lucida's "Original" format hands that back unchanged — wrapped in an MP4
/// container with an `.mp4` filename. There's no better format to request
/// (asking Lucida for MP3/FLAC would just transcode the same AAC and lose
/// quality), so we keep the native audio and fix the container instead.
/// `AudioFileFormat` doesn't recognise `.mp4`, so left alone those files
/// were mis-tagged and never showed up in the library.
///
/// Strategies, best first:
///  1. Audio-only AAC/ALAC → rename to `.m4a`. Bytes untouched, tags kept.
///  2. Anything else (video track present, unusual codec) → copy only the
///     best audio track into a new `.m4a` without re-encoding.
///  3. Last resort, if a copy isn't possible → re-encode the audio to AAC.
/// The source `.mp4` is removed once an `.m4a` exists.
enum AudioContainerNormalizer {
    /// Extensions treated as MP4-family containers that may need converting.
    static let containerExtensions: Set<String> = ["mp4", "m4v", "mov"]

    enum NormalizeError: LocalizedError {
        case noAudioTrack
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "The downloaded file has no audio track."
            case .exportFailed(let reason):
                return "Couldn't extract audio from the downloaded file: \(reason)"
            }
        }
    }

    /// Returns the file to hand to the rest of the pipeline. Files that
    /// aren't MP4-family containers come back unchanged.
    static func normalize(_ url: URL) async throws -> URL {
        guard containerExtensions.contains(url.pathExtension.lowercased()) else { return url }

        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = try await bestAudioTrack(audioTracks) else {
            throw NormalizeError.noAudioTrack
        }
        let hasVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty

        let dest = url.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: dest)

        // 1. Already an audio file in all but name.
        if !hasVideo, audioTracks.count == 1, try await isM4ANativeCodec(audioTrack) {
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }

        // 2./3. Rebuild with just the chosen audio track.
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NormalizeError.exportFailed("couldn't build audio composition")
        }
        let range = try await audioTrack.load(.timeRange)
        try compTrack.insertTimeRange(range, of: audioTrack, at: .zero)
        let metadata = (try? await asset.load(.metadata)) ?? []

        var lastError: Error?
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            do {
                try await export(composition, preset: preset, metadata: metadata, to: dest)
                try? FileManager.default.removeItem(at: url)
                return dest
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: dest)
            }
        }
        throw NormalizeError.exportFailed(lastError?.localizedDescription ?? "unknown error")
    }

    // MARK: - Helpers

    /// Highest-bitrate audio track, so multi-track files keep the best one.
    private static func bestAudioTrack(_ tracks: [AVAssetTrack]) async throws -> AVAssetTrack? {
        var best: (track: AVAssetTrack, rate: Float)?
        for track in tracks {
            let rate = try await track.load(.estimatedDataRate)
            if best == nil || rate > best!.rate { best = (track, rate) }
        }
        return best?.track
    }

    /// AAC variants and ALAC are what `.m4a` players and TagLib expect.
    private static func isM4ANativeCodec(_ track: AVAssetTrack) async throws -> Bool {
        let native: Set<AudioFormatID> = [
            kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
            kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatAppleLossless,
        ]
        let descriptions = try await track.load(.formatDescriptions)
        guard !descriptions.isEmpty else { return false }
        return descriptions.allSatisfy { native.contains(CMFormatDescriptionGetMediaSubType($0)) }
    }

    private static func export(
        _ asset: AVAsset, preset: String, metadata: [AVMetadataItem], to dest: URL
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NormalizeError.exportFailed("preset \(preset) unavailable")
        }
        session.metadata = metadata
        if #available(macOS 15, *) {
            try await session.export(to: dest, as: .m4a)
        } else {
            session.outputURL = dest
            session.outputFileType = .m4a
            await session.export()
            if session.status != .completed {
                throw session.error ?? NormalizeError.exportFailed("export \(preset) did not complete")
            }
        }
    }
}
