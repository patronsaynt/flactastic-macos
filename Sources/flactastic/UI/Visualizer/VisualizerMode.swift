import Foundation

/// The visualizer's modes, in the order the left-edge mode dial presents
/// them. `allCases` order is load-bearing — the dial steps through it.
enum VisualizerMode: String, CaseIterable, Codable, Identifiable {
    case albumArtWheel
    case record
    case lyrics
    case spectrumRadial
    case spectrumHorizontal
    case spectrogram

    var id: String { rawValue }

    /// The mode's name, set large on the dial.
    var dialLabel: String {
        switch self {
        case .albumArtWheel:      return "Cover Wheel"
        case .record:             return "Record"
        case .lyrics:             return "Lyrics"
        case .spectrumRadial:     return "Radial Spectrum"
        case .spectrumHorizontal: return "Horizontal Spectrum"
        case .spectrogram:        return "Spectrogram"
        }
    }

    /// The short name printed small around the dial's rim.
    var rimLabel: String {
        switch self {
        case .albumArtWheel:      return "WHEEL"
        case .record:             return "RECORD"
        case .lyrics:             return "LYRICS"
        case .spectrumRadial:     return "RADIAL"
        case .spectrumHorizontal: return "BARS"
        case .spectrogram:        return "SPECTRO"
        }
    }

    var requiresAudioTap: Bool {
        switch self {
        case .spectrumRadial, .spectrumHorizontal, .spectrogram:
            return true
        default:
            return false
        }
    }
}
