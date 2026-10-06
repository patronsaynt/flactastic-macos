import CoreAudioTypes
import Foundation

enum AudioFileFormat: String, Sendable, CaseIterable, Hashable {
    case flac
    case mp3
    case wav
    case aiff
    case alac
    case aac

    var displayName: String {
        switch self {
        case .flac: return "FLAC"
        case .mp3: return "MP3"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .alac: return "ALAC"
        case .aac: return "AAC"
        }
    }

    static func classify(_ url: URL) -> AudioFileFormat? {
        classify(pathExtension: url.pathExtension)
    }

    /// Classifies a moved file's new URL without losing a codec refinement:
    /// an `.m4a` already known to be AAC stays AAC. Falls back to `current`
    /// when the new extension isn't recognized.
    static func classify(_ url: URL, keeping current: AudioFileFormat) -> AudioFileFormat {
        guard let guessed = classify(url) else { return current }
        if guessed == .alac, current == .aac { return .aac }
        return guessed
    }

    static func classify(pathExtension ext: String) -> AudioFileFormat? {
        switch ext.lowercased() {
        case "flac": return .flac
        case "mp3": return .mp3
        case "wav", "wave": return .wav
        case "aif", "aiff": return .aiff
        case "m4a": return .alac // ALAC or AAC; `refine(_:codec:)` settles it once the file is opened
        case "aac": return .aac
        default: return nil
        }
    }

    /// The real codec behind an MP4-family guess. `.m4a` holds either ALAC or
    /// AAC, so the extension alone can't tell them apart. Returns `nil` when
    /// `format` isn't MP4-family or the codec is something else.
    static func refine(_ format: AudioFileFormat, codec: AudioFormatID) -> AudioFileFormat? {
        guard format == .alac || format == .aac else { return nil }
        switch codec {
        case kAudioFormatAppleLossless:
            return .alac
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD:
            return .aac
        default:
            return nil
        }
    }
}
