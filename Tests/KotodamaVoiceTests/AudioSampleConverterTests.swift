import AVFoundation
import Testing
@testable import KotodamaVoice

@Test func convertsStereo48kHzToMono16kHzFloat32() throws {
    let inputFormat = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )
    )
    let input = try #require(
        AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: 48_000
        )
    )
    input.frameLength = 48_000
    let channels = try #require(input.floatChannelData)
    for frame in 0..<48_000 {
        channels[0][frame] = 0.25
        channels[1][frame] = 0.75
    }

    let output = try AudioSampleConverter().convertToMono16kHz(input)

    #expect(output.format.sampleRate == 16_000)
    #expect(output.format.channelCount == 1)
    #expect(output.format.commonFormat == .pcmFormatFloat32)
    #expect(output.frameLength == 16_000)
    let samples = try #require(output.floatChannelData?[0])
    #expect(abs(samples[8_000] - 0.5) < 0.001)
}
