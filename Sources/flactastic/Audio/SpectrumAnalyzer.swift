import AVFoundation
import Accelerate
import Observation
import os

/// Real-time FFT analyzer driven by an `AVAudioEngine` tap. Decouples audio
/// callbacks from UI redraws: the tap produces an FFT target whenever the
/// hardware delivers a buffer (typically ~10 Hz on macOS), and a 60 Hz timer
/// on the main actor smoothly interpolates `magnitudes` toward that target.
/// SwiftUI redraws every tick, so the bars look fluid even when the audio
/// thread is firing at a low rate.
///
/// Lifecycle: `attach(to:)` installs the tap and starts the display timer;
/// `detach()` tears both down. Keep it detached when no spectrum mode is
/// active to avoid unnecessary FFT cost.
@Observable
@MainActor
final class SpectrumAnalyzer {

    /// Number of output bins exposed to the UI.
    nonisolated static let binCount: Int = 64

    nonisolated private static let fftSize: Int = 1024
    nonisolated private static let log2N: vDSP_Length = vDSP_Length(log2(Double(fftSize)))
    /// Silent frames (at `displayHz`) before the display tick goes quiet:
    /// long enough for the spectrogram to scroll its last sound off screen.
    nonisolated private static let idleFrameLimit: Int = 512
    nonisolated private static let displayHz: Double = 60

    /// Smoothed, log-binned magnitudes in [0, 1]. Always `binCount` long.
    private(set) var magnitudes: [Float] = Array(repeating: 0, count: SpectrumAnalyzer.binCount)

    private weak var engine: PlayerEngine?
    private var isAttached = false
    private var displayTimer: Timer?

    /// Consecutive near-silent display frames. Once the bars have decayed and
    /// the spectrogram has had time to scroll to silence, the display tick
    /// stops writing observable state — so a paused visualizer costs no
    /// redraws. Any non-silent buffer resumes it.
    private var idleFrameStreak: Int = 0
    nonisolated private static let idleEpsilon: Float = 0.001

    /// Latest FFT result, written by the audio thread and read by the
    /// display timer. The lock is uncontended in practice — the audio
    /// thread holds it for nanoseconds and the main thread reads at 60 Hz.
    nonisolated private let target = OSAllocatedUnfairLock<[Float]>(
        initialState: Array(repeating: 0, count: SpectrumAnalyzer.binCount)
    )

    init() {}

    func attach(to engine: PlayerEngine) {
        guard !isAttached else { return }
        self.engine = engine
        isAttached = true

        // FFT setup, window, and scratch buffers are allocated once here and
        // owned by the tap closure — allocating them per buffer (let alone
        // creating/destroying the FFT setup) on the audio thread is the kind
        // of work real-time callbacks must avoid. Released when the tap is.
        guard let fft = FFTResources(fftSize: Self.fftSize, log2N: Self.log2N) else { return }
        engine.installAnalysisTap(bufferSize: AVAudioFrameCount(Self.fftSize)) { [target] buffer, _ in
            // FFT runs on the audio thread (cheap; ~µs for a 1024-pt FFT).
            // Result is published to the lock — the display timer will
            // pick it up on the next tick.
            guard let mags = fft.computeMagnitudes(from: buffer, binCount: Self.binCount) else { return }
            target.withLock { $0 = mags }
        }

        startDisplayTimer()
    }

    func detach() {
        guard isAttached else { return }
        engine?.removeAnalysisTap()
        isAttached = false
        displayTimer?.invalidate()
        displayTimer = nil
        target.withLock { $0 = Array(repeating: 0, count: Self.binCount) }
        magnitudes = Array(repeating: 0, count: Self.binCount)
        idleFrameStreak = 0
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / Self.displayHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    /// Per-frame interpolation: fast attack toward higher targets, gentle
    /// decay otherwise. This makes spikes pop while letting silence fade
    /// out smoothly — the visual signature of music-spectrum displays.
    private func tick() {
        let latest = target.withLock { $0 }

        // Fully settled (paused/silent long enough that bars and spectrogram
        // are both blank): skip all observable writes so SwiftUI stops
        // redrawing. The checks are a few hundred float compares — trivial
        // next to a 60 fps Canvas redraw.
        if idleFrameStreak >= Self.idleFrameLimit,
           latest.allSatisfy({ $0 < Self.idleEpsilon }),
           magnitudes.allSatisfy({ $0 < Self.idleEpsilon }) {
            return
        }

        let count = magnitudes.count
        var smoothed = magnitudes
        smoothed.withUnsafeMutableBufferPointer { dst in
            latest.withUnsafeBufferPointer { src in
                for i in 0..<count {
                    let t = src[i]
                    if t > dst[i] {
                        // Fast attack: 60% of the way to the new peak per frame.
                        dst[i] += (t - dst[i]) * 0.6
                    } else {
                        // Decay: ~3% per frame at 60 Hz ≈ 0.85/sec.
                        dst[i] *= 0.97
                    }
                }
            }
        }
        magnitudes = smoothed

        if smoothed.allSatisfy({ $0 < Self.idleEpsilon }) {
            idleFrameStreak += 1
        } else {
            idleFrameStreak = 0
        }
    }

    // MARK: - FFT (audio thread)

    /// One-time FFT state reused across audio-tap invocations: the vDSP setup,
    /// the Hann window, and mutable scratch buffers.
    ///
    /// `@unchecked Sendable` invariant: AVAudioEngine invokes a given node tap
    /// serially, and this object is only ever used from inside one tap closure,
    /// so the mutable scratch buffers are never touched by two threads at once.
    /// `setup` and `window` are immutable after init.
    nonisolated private final class FFTResources: @unchecked Sendable {
        private let setup: FFTSetup
        private let window: [Float]
        private let fftSize: Int
        private let log2N: vDSP_Length
        private var samples: [Float]
        private var realp: [Float]
        private var imagp: [Float]
        private var magnitudes: [Float]

        init?(fftSize: Int, log2N: vDSP_Length) {
            guard let setup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else { return nil }
            self.setup = setup
            self.fftSize = fftSize
            self.log2N = log2N
            var window = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
            self.window = window
            let half = fftSize / 2
            samples = [Float](repeating: 0, count: fftSize)
            realp = [Float](repeating: 0, count: half)
            imagp = [Float](repeating: 0, count: half)
            magnitudes = [Float](repeating: 0, count: half)
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        /// Applies the Hann window, runs a real-to-complex FFT, then aggregates
        /// the linear spectrum into log-spaced bins normalized to [0, 1].
        func computeMagnitudes(from buffer: AVAudioPCMBuffer, binCount: Int) -> [Float]? {
            guard let channelData = buffer.floatChannelData else { return nil }
            let frameLength = Int(buffer.frameLength)
            guard frameLength >= fftSize else { return nil }

            let src = channelData[0]
            for i in 0..<fftSize { samples[i] = src[i] }
            vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

            let half = fftSize / 2
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    samples.withUnsafeBufferPointer { sp in
                        sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2N, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }

            var scale: Float = 1.0 / Float(fftSize)
            vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))

            var output = [Float](repeating: 0, count: binCount)
            let minIdx: Float = 1
            let maxIdx: Float = Float(half - 1)
            for b in 0..<binCount {
                let t0 = Float(b) / Float(binCount)
                let t1 = Float(b + 1) / Float(binCount)
                let lo = Int(minIdx * powf(maxIdx / minIdx, t0))
                let hi = max(lo + 1, Int(minIdx * powf(maxIdx / minIdx, t1)))
                let upper = min(hi, half)
                var peak: Float = 0
                for i in lo..<upper { peak = max(peak, magnitudes[i]) }
                output[b] = min(1, sqrtf(peak * 8))
            }
            return output
        }
    }
}
