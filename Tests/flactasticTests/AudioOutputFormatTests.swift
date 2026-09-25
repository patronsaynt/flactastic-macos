import CoreAudio
import Foundation
import Testing
@testable import flactastic

// MARK: - expandRates

@Test func expandRatesKeepsDiscreteValues() {
    let ranges = [
        AudioValueRange(mMinimum: 48_000, mMaximum: 48_000),
        AudioValueRange(mMinimum: 44_100, mMaximum: 44_100),
    ]
    #expect(AudioHAL.expandRates(ranges) == [44_100, 48_000])
}

@Test func expandRatesExpandsContinuousRangeToStandardRates() {
    let ranges = [AudioValueRange(mMinimum: 44_100, mMaximum: 192_000)]
    #expect(AudioHAL.expandRates(ranges) == [44_100, 48_000, 88_200, 96_000, 176_400, 192_000])
}

@Test func expandRatesDeduplicatesOverlaps() {
    let ranges = [
        AudioValueRange(mMinimum: 44_100, mMaximum: 96_000),
        AudioValueRange(mMinimum: 96_000, mMaximum: 96_000),
        AudioValueRange(mMinimum: 88_200, mMaximum: 192_000),
    ]
    #expect(AudioHAL.expandRates(ranges) == [44_100, 48_000, 88_200, 96_000, 176_400, 192_000])
}

@Test func expandRatesIgnoresEmptyInput() {
    #expect(AudioHAL.expandRates([]).isEmpty)
}

// MARK: - bitDepths

private func pcm(bits: UInt32, rate: Double, min: Double = 0, max: Double = 0,
                 float: Bool = false, formatID: AudioFormatID = kAudioFormatLinearPCM) -> AudioStreamRangedDescription {
    var asbd = AudioStreamBasicDescription()
    asbd.mFormatID = formatID
    asbd.mSampleRate = rate
    asbd.mBitsPerChannel = bits
    asbd.mChannelsPerFrame = 2
    asbd.mFormatFlags = float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
    return AudioStreamRangedDescription(
        mFormat: asbd,
        mSampleRateRange: AudioValueRange(mMinimum: min == 0 ? rate : min, mMaximum: max == 0 ? rate : max)
    )
}

@Test func bitDepthsFiltersBySampleRate() {
    let formats = [
        pcm(bits: 16, rate: 44_100),
        pcm(bits: 24, rate: 44_100),
        pcm(bits: 24, rate: 96_000),
        pcm(bits: 32, rate: 96_000),
    ]
    #expect(AudioHAL.bitDepths(from: formats, sampleRate: 44_100) == [16, 24])
    #expect(AudioHAL.bitDepths(from: formats, sampleRate: 96_000) == [24, 32])
}

@Test func bitDepthsHonoursAnyRateRanges() {
    let formats = [pcm(bits: 24, rate: kAudioStreamAnyRate, min: 44_100, max: 192_000)]
    #expect(AudioHAL.bitDepths(from: formats, sampleRate: 96_000) == [24])
    #expect(AudioHAL.bitDepths(from: formats, sampleRate: 384_000).isEmpty)
}

@Test func bitDepthsExcludesNonPCMAndDeduplicates() {
    let formats = [
        pcm(bits: 24, rate: 48_000),
        pcm(bits: 24, rate: 48_000, float: true),
        pcm(bits: 32, rate: 48_000, float: true),
        pcm(bits: 16, rate: 48_000),
        pcm(bits: 16, rate: 48_000, formatID: kAudioFormatAC3),
    ]
    #expect(AudioHAL.bitDepths(from: formats, sampleRate: 48_000) == [16, 24, 32])
}
