import AVFoundation
import CoreAudio

// MARK: - Protocol for portability

protocol AudioGraphProtocol: AnyObject, Sendable {
    var canonicalFormat: AVAudioFormat { get }
    func prepare() throws
    func reprepare()
    func schedule(_ buffer: AVAudioPCMBuffer, completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
                  completionHandler: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void)
    func play()
    func pause()
    func flush()
    var isNodePlaying: Bool { get }
    func currentPlayerSampleTime() -> AVAudioFramePosition?
    func setOutputVolume(_ volume: Float)
    func onConfigurationChange(_ handler: @escaping @Sendable () -> Void)

    /// Route output to `config.deviceID` and apply the requested device rate /
    /// physical bit depth. Restarts the engine only if it was running.
    func applyOutput(_ config: AudioOutputConfig) throws

    /// True when the engine is running at the output device's current rate —
    /// i.e. a configuration-change notification needs no rebuild.
    var isInSyncWithDevice: Bool { get }

    /// Install a tap on the main mixer for analysis (FFT / visualization).
    /// The block is called on a background audio thread; consumers must hop
    /// to the main actor before publishing observed state.
    func installAnalysisTap(bufferSize: AVAudioFrameCount,
                            _ block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)
    func removeAnalysisTap()
}

// MARK: - Apple AVAudioEngine implementation

final class AppleAudioGraph: AudioGraphProtocol, @unchecked Sendable {
    /// The canonical processing format, derived from the output device's sample rate.
    /// Set during `prepare()` / `reprepare()`. Always stereo Float32 non-interleaved.
    private(set) var canonicalFormat: AVAudioFormat

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var configChangeObserver: Any?
    private var isAttached = false
    private var hasAnalysisTap = false
    private var analysisTap: (bufferSize: AVAudioFrameCount,
                              block: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    init() {
        // Placeholder; real format is set in prepare() from the device rate.
        canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    }

    deinit {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        engine.stop()
    }

    func prepare() throws {
        if !isAttached {
            engine.attach(playerNode)
            isAttached = true
        }
        connectGraph()
        try engine.start()
    }

    func reprepare() {
        connectGraph()
        try? engine.start()
    }

    func applyOutput(_ config: AudioOutputConfig) throws {
        let wasRunning = engine.isRunning
        engine.stop()

        // The output unit must be stopped while its device is switched.
        if currentOutputDeviceID() != config.deviceID {
            guard let unit = engine.outputNode.audioUnit else { throw AudioOutputError.noOutputUnit }
            var deviceID = config.deviceID
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw AudioOutputError.deviceSwitchFailed(status) }
        }

        // Rate first (waits for the HAL to settle), then the physical format
        // at that rate. The engine stays Float32; the HAL converts to the
        // device's integer format below us, so bit depth never touches the
        // decode/schedule pipeline.
        if let rate = config.sampleRate {
            AudioHAL.setNominalSampleRate(config.deviceID, rate)
        }
        if let bits = config.bitDepth,
           let rate = config.sampleRate ?? AudioHAL.nominalSampleRate(config.deviceID) {
            AudioHAL.setPhysicalFormat(config.deviceID, bitDepth: bits, sampleRate: rate)
        }

        // Before the first prepare() there's no graph yet — prepare() will
        // build it against the device selected above.
        guard isAttached else { return }
        connectGraph()
        if wasRunning { try engine.start() }
    }

    var isInSyncWithDevice: Bool {
        guard engine.isRunning, let rate = deviceSampleRate() else { return false }
        return rate == canonicalFormat.sampleRate
    }

    func schedule(_ buffer: AVAudioPCMBuffer,
                  completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
                  completionHandler: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) {
        playerNode.scheduleBuffer(buffer, completionCallbackType: completionCallbackType, completionHandler: completionHandler)
    }

    func play() {
        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.play()
    }

    func pause() {
        playerNode.pause()
    }

    func flush() {
        playerNode.stop()
    }

    var isNodePlaying: Bool {
        playerNode.isPlaying
    }

    func currentPlayerSampleTime() -> AVAudioFramePosition? {
        guard let nodeTime = playerNode.lastRenderTime, nodeTime.isSampleTimeValid else { return nil }
        guard let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return nil }
        return playerTime.sampleTime
    }

    func setOutputVolume(_ volume: Float) {
        engine.mainMixerNode.outputVolume = max(0, min(1, volume))
    }

    func onConfigurationChange(_ handler: @escaping @Sendable () -> Void) {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in
            handler()
        }
    }

    // MARK: - Private

    func installAnalysisTap(bufferSize: AVAudioFrameCount,
                            _ block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        if hasAnalysisTap {
            engine.mainMixerNode.removeTap(onBus: 0)
            hasAnalysisTap = false
        }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, when in
            block(buffer, when)
        }
        hasAnalysisTap = true
        analysisTap = (bufferSize, block)
    }

    func removeAnalysisTap() {
        analysisTap = nil
        guard hasAnalysisTap else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        hasAnalysisTap = false
    }

    /// (Re)build player → mixer → output at the device's current rate. The
    /// analysis tap is re-installed so its format follows the new mixer rate.
    private func connectGraph() {
        canonicalFormat = makeCanonicalFormat()
        let tap = analysisTap
        if hasAnalysisTap {
            engine.mainMixerNode.removeTap(onBus: 0)
            hasAnalysisTap = false
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: canonicalFormat)
        let hardwareChannels = engine.outputNode.outputFormat(forBus: 0).channelCount
        if hardwareChannels > 0,
           let mixerFormat = AVAudioFormat(standardFormatWithSampleRate: canonicalFormat.sampleRate,
                                           channels: hardwareChannels) {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: mixerFormat)
        }
        if let tap {
            installAnalysisTap(bufferSize: tap.bufferSize, tap.block)
        }
    }

    private func makeCanonicalFormat() -> AVAudioFormat {
        // Prefer the HAL's nominal rate — the output node's cached format can
        // lag a device switch or rate change.
        let nodeRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let deviceRate = deviceSampleRate() ?? (nodeRate > 0 ? nodeRate : 44_100)
        return AVAudioFormat(standardFormatWithSampleRate: deviceRate, channels: 2)!
    }

    private func currentOutputDeviceID() -> AudioDeviceID? {
        guard let unit = engine.outputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, &size
        )
        return status == noErr && deviceID != AudioDeviceID(kAudioObjectUnknown) ? deviceID : nil
    }

    private func deviceSampleRate() -> Double? {
        guard let device = currentOutputDeviceID(),
              let rate = AudioHAL.nominalSampleRate(device), rate > 0 else { return nil }
        return rate
    }
}

enum AudioOutputError: Error {
    case noOutputUnit
    case deviceSwitchFailed(OSStatus)
}
