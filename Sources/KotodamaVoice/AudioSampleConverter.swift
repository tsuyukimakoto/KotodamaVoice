import AVFoundation

enum AudioSampleConverterError: Error {
    case unsupportedInputFormat
    case cannotCreateFormat
    case cannotCreateConverter
    case conversionFailed
}

struct AudioSampleConverter {
    func convertToMono16kHz(
        _ input: AVAudioPCMBuffer
    ) throws -> AVAudioPCMBuffer {
        guard input.format.commonFormat == .pcmFormatFloat32,
              !input.format.isInterleaved,
              let inputChannels = input.floatChannelData
        else {
            throw AudioSampleConverterError.unsupportedInputFormat
        }
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: input.format.sampleRate,
            channels: 1,
            interleaved: false
        ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ),
            let monoInput = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: input.frameLength
            ),
            let monoChannel = monoInput.floatChannelData?[0]
        else {
            throw AudioSampleConverterError.cannotCreateFormat
        }

        monoInput.frameLength = input.frameLength
        let channelCount = Int(input.format.channelCount)
        let scale = 1 / Float(channelCount)
        for frame in 0..<Int(input.frameLength) {
            var mixedSample: Float = 0
            for channel in 0..<channelCount {
                mixedSample += inputChannels[channel][frame]
            }
            monoChannel[frame] = mixedSample * scale
        }

        guard let converter = AVAudioConverter(
            from: monoFormat,
            to: outputFormat
        ) else {
            throw AudioSampleConverterError.cannotCreateConverter
        }
        let expectedFrames = ceil(
            Double(input.frameLength) * outputFormat.sampleRate
                / input.format.sampleRate
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(expectedFrames + 64)
        ) else {
            throw AudioSampleConverterError.cannotCreateFormat
        }

        let inputProvider = AudioConverterInputProvider(buffer: monoInput)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            _, inputStatus in
            guard let input = inputProvider.takeBuffer() else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil else {
            throw conversionError ?? AudioSampleConverterError.conversionFailed
        }
        return output
    }
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func takeBuffer() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !wasSupplied else { return nil }
        wasSupplied = true
        return buffer
    }
}
