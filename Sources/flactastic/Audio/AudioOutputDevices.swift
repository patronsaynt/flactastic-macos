import CoreAudio
import Foundation
import Observation

// MARK: - Models

/// A Core Audio device with at least one output stream. Persisted by `uid`,
/// which is stable across reboots and re-plugs; `id` is not.
struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// What the audio graph should output through. `nil` rate / bit depth means
/// "leave the device's current setting alone".
struct AudioOutputConfig: Equatable, Sendable {
    var deviceID: AudioDeviceID
    var sampleRate: Double?
    var bitDepth: Int?
}

// MARK: - HAL helpers

/// Thin wrapper over the Core Audio HAL property API. Everything here is
/// synchronous; callers run it on the main actor in response to user actions
/// or hardware notifications.
enum AudioHAL {

    /// Rates offered when a device reports a continuous range rather than
    /// discrete values.
    static let standardRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000,
        352_800, 384_000, 705_600, 768_000,
    ]

    // MARK: Devices

    static func outputDevices() -> [AudioOutputDevice] {
        let ids: [AudioDeviceID] = array(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
        return ids.compactMap { id in
            guard !outputStreams(id).isEmpty,
                  let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            return AudioOutputDevice(id: id, uid: uid, name: name)
        }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID {
        value(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice))
            ?? AudioDeviceID(kAudioObjectUnknown)
    }

    // MARK: Sample rate

    static func availableSampleRates(_ device: AudioDeviceID) -> [Double] {
        let ranges: [AudioValueRange] = array(device, address(kAudioDevicePropertyAvailableNominalSampleRates))
        return expandRates(ranges)
    }

    /// Discrete entries (min == max) pass through; continuous ranges are
    /// expanded to the standard rates they contain. Sorted, de-duplicated.
    static func expandRates(_ ranges: [AudioValueRange]) -> [Double] {
        var rates = Set<Double>()
        for range in ranges {
            if range.mMinimum == range.mMaximum {
                if range.mMinimum > 0 { rates.insert(range.mMinimum) }
            } else {
                for rate in standardRates where rate >= range.mMinimum && rate <= range.mMaximum {
                    rates.insert(rate)
                }
            }
        }
        return rates.sorted()
    }

    static func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
        value(device, address(kAudioDevicePropertyNominalSampleRate))
    }

    /// Sets the device's nominal rate and waits (up to ~1 s) for the HAL to
    /// report it, since rate changes land asynchronously.
    @discardableResult
    static func setNominalSampleRate(_ device: AudioDeviceID, _ rate: Double) -> Bool {
        if nominalSampleRate(device) == rate { return true }
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var newRate = Float64(rate)
        let status = AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &newRate
        )
        guard status == noErr else {
            print("[AudioHAL] Failed to set sample rate \(rate): \(status)")
            return false
        }
        for _ in 0..<50 {
            if nominalSampleRate(device) == rate { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nominalSampleRate(device) == rate
    }

    // MARK: Bit depth

    static func availableBitDepths(_ device: AudioDeviceID, sampleRate: Double) -> [Int] {
        guard let stream = outputStreams(device).first else { return [] }
        return bitDepths(from: physicalFormats(stream), sampleRate: sampleRate)
    }

    /// Linear-PCM formats whose rate range covers `sampleRate`, reduced to
    /// their sorted, unique bits-per-channel.
    static func bitDepths(from formats: [AudioStreamRangedDescription], sampleRate: Double) -> [Int] {
        var depths = Set<Int>()
        for f in formats where supports(f, sampleRate: sampleRate) {
            depths.insert(Int(f.mFormat.mBitsPerChannel))
        }
        return depths.sorted()
    }

    static func physicalBitDepth(_ device: AudioDeviceID) -> Int? {
        guard let stream = outputStreams(device).first,
              let asbd: AudioStreamBasicDescription = value(stream, address(kAudioStreamPropertyPhysicalFormat))
        else { return nil }
        return Int(asbd.mBitsPerChannel)
    }

    /// Switches the first output stream's physical format to `bitDepth` at
    /// `sampleRate`, keeping the current channel count and preferring integer
    /// formats (what DACs actually take) over float ones.
    @discardableResult
    static func setPhysicalFormat(_ device: AudioDeviceID, bitDepth: Int, sampleRate: Double) -> Bool {
        guard let stream = outputStreams(device).first else { return false }
        let current: AudioStreamBasicDescription? = value(stream, address(kAudioStreamPropertyPhysicalFormat))
        if let current, Int(current.mBitsPerChannel) == bitDepth, current.mSampleRate == sampleRate {
            return true
        }

        let candidates = physicalFormats(stream).filter {
            supports($0, sampleRate: sampleRate) && Int($0.mFormat.mBitsPerChannel) == bitDepth
        }
        let channels = current?.mChannelsPerFrame
        func isFloat(_ f: AudioStreamRangedDescription) -> Bool {
            f.mFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0
        }
        let ranked = candidates.sorted { a, b in
            let aScore = (isFloat(a) ? 0 : 2) + (a.mFormat.mChannelsPerFrame == channels ? 1 : 0)
            let bScore = (isFloat(b) ? 0 : 2) + (b.mFormat.mChannelsPerFrame == channels ? 1 : 0)
            return aScore > bScore
        }
        guard var format = ranked.first?.mFormat else { return false }
        format.mSampleRate = sampleRate

        var addr = address(kAudioStreamPropertyPhysicalFormat)
        let status = AudioObjectSetPropertyData(
            stream, &addr, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format
        )
        if status != noErr {
            print("[AudioHAL] Failed to set \(bitDepth)-bit physical format: \(status)")
        }
        return status == noErr
    }

    // MARK: Streams

    static func outputStreams(_ device: AudioDeviceID) -> [AudioStreamID] {
        array(device, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput))
    }

    private static func physicalFormats(_ stream: AudioStreamID) -> [AudioStreamRangedDescription] {
        array(stream, address(kAudioStreamPropertyAvailablePhysicalFormats))
    }

    private static func supports(_ f: AudioStreamRangedDescription, sampleRate: Double) -> Bool {
        guard f.mFormat.mFormatID == kAudioFormatLinearPCM, f.mFormat.mBitsPerChannel > 0 else { return false }
        if f.mFormat.mSampleRate == sampleRate { return true }
        // A zero rate (kAudioStreamAnyRate) defers to the ranged bounds.
        return f.mFormat.mSampleRate == kAudioStreamAnyRate
            && sampleRate >= f.mSampleRateRange.mMinimum
            && sampleRate <= f.mSampleRateRange.mMaximum
    }

    // MARK: Property plumbing

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> T? {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    private static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [T] {
        var addr = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            var readSize = size
            let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &readSize, buffer.baseAddress!)
            initialized = status == noErr ? Int(readSize) / MemoryLayout<T>.stride : 0
        }
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }
}

// MARK: - Manager

/// Owns the user-facing output selection: enumerates devices, tracks the
/// selected device's capabilities, follows hot-plug / default-device changes,
/// and pushes the resulting config into the `PlayerEngine`.
///
/// Gapless contract: the engine resamples every track to one fixed device
/// rate, so nothing here ever changes the rate between tracks. Config is only
/// applied at launch (before playback) or on an explicit user / hardware event.
@Observable
@MainActor
final class AudioOutputManager {
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var defaultDeviceID = AudioDeviceID(kAudioObjectUnknown)

    /// Capabilities and live state of the effective device.
    private(set) var availableSampleRates: [Double] = []
    private(set) var availableBitDepths: [Int] = []
    private(set) var currentSampleRate: Double?
    private(set) var currentBitDepth: Int?

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let engine: PlayerEngine
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var systemListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var deviceListenerRegistrations: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var observedDeviceID = AudioDeviceID(kAudioObjectUnknown)

    private static let systemSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultOutputDevice,
    ]

    init(settings: Settings, engine: PlayerEngine) {
        self.settings = settings
        self.engine = engine
    }

    // MARK: Derived state

    var selectedDeviceUID: String? { settings.outputDeviceUID }
    var selectedSampleRate: Double? { settings.outputSampleRate }
    var selectedBitDepth: Int? { settings.outputBitDepth }

    var defaultDevice: AudioOutputDevice? { devices.first { $0.id == defaultDeviceID } }

    /// The saved device when it's connected, otherwise the system default.
    var effectiveDevice: AudioOutputDevice? {
        if let uid = settings.outputDeviceUID, let device = devices.first(where: { $0.uid == uid }) {
            return device
        }
        return defaultDevice
    }

    /// True when the user pinned a device that isn't currently connected.
    var isSelectedDeviceMissing: Bool {
        guard let uid = settings.outputDeviceUID else { return false }
        return !devices.contains { $0.uid == uid }
    }

    private var effectiveDeviceID: AudioDeviceID { effectiveDevice?.id ?? defaultDeviceID }

    // MARK: Lifecycle

    /// Registers hardware listeners and applies the saved configuration.
    /// Called once at launch, before any playback, so it never interrupts audio.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.handleSystemChange() }
        }
        systemListener = listener
        for selector in Self.systemSelectors {
            var addr = AudioHAL.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
        }

        refreshDevices()
        apply()
    }

    // MARK: User selection

    func selectDevice(uid: String?) {
        guard uid != settings.outputDeviceUID else { return }
        settings.outputDeviceUID = uid
        refreshCapabilities()
        // Drop choices the new device can't honour.
        if let rate = settings.outputSampleRate, !availableSampleRates.contains(rate) {
            settings.outputSampleRate = nil
        }
        dropUnsupportedBitDepth()
        apply()
    }

    func selectSampleRate(_ rate: Double?) {
        guard rate != settings.outputSampleRate else { return }
        settings.outputSampleRate = rate
        refreshCapabilities()
        dropUnsupportedBitDepth()
        apply()
    }

    func selectBitDepth(_ bits: Int?) {
        guard bits != settings.outputBitDepth else { return }
        settings.outputBitDepth = bits
        apply()
    }

    private func dropUnsupportedBitDepth() {
        if let bits = settings.outputBitDepth, !availableBitDepths.contains(bits) {
            settings.outputBitDepth = nil
        }
    }

    // MARK: Applying

    /// Pushes the effective config into the engine. Saved rate / bit depth
    /// are only used when the effective device supports them, so falling back
    /// to the default device (e.g. DAC unplugged) never wipes the user's choice.
    private func apply() {
        let device = effectiveDeviceID
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return }

        let rates = AudioHAL.availableSampleRates(device)
        let rate = settings.outputSampleRate.flatMap { rates.contains($0) ? $0 : nil }
        let depthRate = rate ?? AudioHAL.nominalSampleRate(device) ?? 0
        let depths = AudioHAL.availableBitDepths(device, sampleRate: depthRate)
        let bits = settings.outputBitDepth.flatMap { depths.contains($0) ? $0 : nil }

        engine.applyOutputConfiguration(AudioOutputConfig(deviceID: device, sampleRate: rate, bitDepth: bits))
        refreshCapabilities()
    }

    // MARK: Hardware events

    private func handleSystemChange() {
        let previous = effectiveDeviceID
        refreshDevices()
        // Re-route only when the device we should be using actually changed:
        // pinned DAC unplugged / re-plugged, or the system default moved while
        // we're following it.
        if effectiveDeviceID != previous {
            apply()
        }
    }

    private func refreshDevices() {
        devices = AudioHAL.outputDevices()
        defaultDeviceID = AudioHAL.defaultOutputDeviceID()
        refreshCapabilities()
    }

    private func refreshCapabilities() {
        let device = effectiveDeviceID
        observeDevice(device)
        availableSampleRates = AudioHAL.availableSampleRates(device)
        currentSampleRate = AudioHAL.nominalSampleRate(device)
        let depthRate = settings.outputSampleRate ?? currentSampleRate ?? 0
        availableBitDepths = AudioHAL.availableBitDepths(device, sampleRate: depthRate)
        currentBitDepth = AudioHAL.physicalBitDepth(device)
    }

    /// Keeps the displayed rate / format live when they change underneath us
    /// (e.g. edited in Audio MIDI Setup). Display-only: the engine picks up
    /// such changes through its own configuration-change handling.
    private func observeDevice(_ device: AudioDeviceID) {
        guard device != observedDeviceID else { return }
        if let deviceListener {
            for (object, address) in deviceListenerRegistrations {
                var addr = address
                AudioObjectRemovePropertyListenerBlock(object, &addr, .main, deviceListener)
            }
        }
        deviceListenerRegistrations.removeAll()
        observedDeviceID = device
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshCapabilities() }
        }
        deviceListener = listener

        var targets: [(AudioObjectID, AudioObjectPropertyAddress)] = [
            (device, AudioHAL.address(kAudioDevicePropertyNominalSampleRate)),
            (device, AudioHAL.address(kAudioDevicePropertyAvailableNominalSampleRates)),
        ]
        if let stream = AudioHAL.outputStreams(device).first {
            targets.append((stream, AudioHAL.address(kAudioStreamPropertyPhysicalFormat)))
        }
        for (object, address) in targets {
            var addr = address
            if AudioObjectAddPropertyListenerBlock(object, &addr, .main, listener) == noErr {
                deviceListenerRegistrations.append((object, address))
            }
        }
    }
}
