import AVFoundation
import Testing
@testable import KotodamaVoice

@Test func audioAccumulatorRejectsFramesBeyondMaximum() throws {
    let accumulator = AudioBufferAccumulator(maximumFrameCount: 15)
    let buffer = try audioBuffer(frameCount: 10)

    #expect(accumulator.appendCopy(of: buffer) == .accepted)
    #expect(
        accumulator.appendCopy(of: buffer) == .maximumFrameCountExceeded
    )
    #expect(try accumulator.joinedBuffer().frameLength == 10)
}

@Test func audioAccumulatorResetDiscardsPartialRecording() throws {
    let accumulator = AudioBufferAccumulator()
    _ = accumulator.appendCopy(of: try audioBuffer(frameCount: 10))

    accumulator.reset()

    #expect(throws: AudioRecordingError.emptyRecording) {
        try accumulator.joinedBuffer()
    }
}

@Test func audioAccumulatorTreatsZeroFramesAsEmptyRecording() throws {
    let accumulator = AudioBufferAccumulator()

    #expect(
        accumulator.appendCopy(of: try audioBuffer(frameCount: 0))
            == .accepted
    )
    #expect(throws: AudioRecordingError.emptyRecording) {
        try accumulator.joinedBuffer()
    }
}

@Test @MainActor
func audioInputTapCanRunOutsideTheMainActor() async throws {
    try await confirmation { failureReported in
        let receiver = AudioInputTapReceiver(
            accumulator: AudioBufferAccumulator(maximumFrameCount: 0),
            onMaximumDurationExceeded: {
                #expect(Thread.isMainThread)
                failureReported()
            }
        )
        let tap = makeAudioInputTap(receiver: receiver)

        try await Task.detached {
            let format = try #require(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 48_000,
                    channels: 1,
                    interleaved: false
                )
            )
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)
            )
            buffer.frameLength = 1
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
        }.value
    }
}

private func audioBuffer(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
    let format = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )
    )
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    )
    buffer.frameLength = frameCount
    return buffer
}
