import AVFoundation
import Foundation
import SoundAnalysis

/// Listens to three 3-second slices of a track (at a quarter, half and three
/// quarters through) with Apple's built-in sound classifier, on this Mac,
/// and keeps the 32 strongest categories as the track's fingerprint. Nothing
/// leaves the machine; well under a second per track once the classifier
/// has loaded (1.5s for the first, load included).
enum SoundFingerprinter {
    static func fingerprint(of url: URL) async -> SoundFingerprint? {
        await Task.detached(priority: .utility) { analyse(url) }.value
    }

    private static func analyse(_ url: URL) -> SoundFingerprint? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sliceFrames = AVAudioFrameCount(format.sampleRate * 3)
        guard file.length > Int64(sliceFrames) * 2,
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sliceFrames) else { return nil }

        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = Collector()
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return nil }

        for fraction in [0.25, 0.5, 0.75] {
            let start = AVAudioFramePosition(Double(file.length) * fraction)
            file.framePosition = start
            buffer.frameLength = 0
            guard (try? file.read(into: buffer, frameCount: sliceFrames)) != nil, buffer.frameLength > 0 else { continue }
            analyzer.analyze(buffer, atAudioFramePosition: start)
        }
        analyzer.completeAnalysis()
        return observer.fingerprint()
    }

    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        private var sums: [String: Float] = [:]
        private var count: Float = 0
        private let lock = NSLock()

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            lock.lock(); defer { lock.unlock() }
            count += 1
            for c in result.classifications where c.confidence > 0.01 {
                sums[c.identifier, default: 0] += Float(c.confidence)
            }
        }

        func fingerprint() -> SoundFingerprint? {
            lock.lock(); defer { lock.unlock() }
            guard count > 0 else { return nil }
            let top = sums.sorted { $0.value > $1.value }.prefix(32)
            return SoundFingerprint(classes: Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value / count) }))
        }
    }
}
