import AVFoundation

enum AudioRecordingError: Error {
    case alreadyRecording
    case notRecording
    case unavailableInput
    case emptyRecording
    case formatChanged
    case cannotAllocateBuffer
    case maximumDurationExceeded
    case inputConfigurationChanged
}

@MainActor
final class AudioRecordingService {
    private let engine: AVAudioEngine
    private let maximumDuration: TimeInterval
    private var accumulator = AudioBufferAccumulator()
    private let converter: AudioSampleConverter
    private var isRecording = false
    private var configurationObserver: NSObjectProtocol?

    var onFailure: (@MainActor @Sendable (Error) -> Void)?

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        converter: AudioSampleConverter = AudioSampleConverter(),
        maximumDuration: TimeInterval = 300
    ) {
        self.engine = engine
        self.converter = converter
        self.maximumDuration = maximumDuration
    }

    func start() throws {
        guard !isRecording else {
            throw AudioRecordingError.alreadyRecording
        }
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved
        else {
            throw AudioRecordingError.unavailableInput
        }

        accumulator = AudioBufferAccumulator(
            maximumFrameCount: UInt64(format.sampleRate * maximumDuration)
        )
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: format
        ) { [weak self, accumulator] buffer, _ in
            guard accumulator.appendCopy(of: buffer) == .accepted else {
                Task { @MainActor in
                    self?.failRecording(with: .maximumDurationExceeded)
                }
                return
            }
        }
        engine.prepare()
        do {
            try engine.start()
            isRecording = true
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.failRecording(with: .inputConfigurationChanged)
                }
            }
        } catch {
            inputNode.removeTap(onBus: 0)
            accumulator.reset()
            throw error
        }
    }

    func stop() throws -> AVAudioPCMBuffer {
        guard isRecording else {
            throw AudioRecordingError.notRecording
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        removeConfigurationObserver()

        defer { accumulator.reset() }
        let input = try accumulator.joinedBuffer()
        return try converter.convertToMono16kHz(input)
    }

    func cancel() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        removeConfigurationObserver()
        accumulator.reset()
    }

    private func failRecording(with error: AudioRecordingError) {
        guard isRecording else { return }
        cancel()
        onFailure?(error)
    }

    private func removeConfigurationObserver() {
        guard let configurationObserver else { return }
        NotificationCenter.default.removeObserver(configurationObserver)
        self.configurationObserver = nil
    }
}

enum AudioBufferAppendResult: Equatable {
    case accepted
    case maximumFrameCountExceeded
}

final class AudioBufferAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var frameCount: UInt64 = 0
    private let maximumFrameCount: UInt64

    init(maximumFrameCount: UInt64 = .max) {
        self.maximumFrameCount = maximumFrameCount
    }

    func appendCopy(of source: AVAudioPCMBuffer) -> AudioBufferAppendResult {
        guard source.frameLength > 0 else { return .accepted }
        lock.lock()
        let proposedFrameCount = frameCount + UInt64(source.frameLength)
        guard proposedFrameCount <= maximumFrameCount else {
            lock.unlock()
            return .maximumFrameCountExceeded
        }
        frameCount = proposedFrameCount
        lock.unlock()

        guard let sourceChannels = source.floatChannelData,
              let copy = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: source.frameLength
              ),
              let destinationChannels = copy.floatChannelData
        else {
            lock.lock()
            frameCount -= UInt64(source.frameLength)
            lock.unlock()
            return .maximumFrameCountExceeded
        }
        copy.frameLength = source.frameLength
        let byteCount = Int(source.frameLength) * MemoryLayout<Float>.size
        for channel in 0..<Int(source.format.channelCount) {
            memcpy(destinationChannels[channel], sourceChannels[channel], byteCount)
        }

        lock.lock()
        buffers.append(copy)
        lock.unlock()
        return .accepted
    }

    func joinedBuffer() throws -> AVAudioPCMBuffer {
        lock.lock()
        let buffers = self.buffers
        lock.unlock()
        guard let first = buffers.first else {
            throw AudioRecordingError.emptyRecording
        }
        guard buffers.allSatisfy({
            $0.format.sampleRate == first.format.sampleRate
                && $0.format.channelCount == first.format.channelCount
                && $0.format.commonFormat == first.format.commonFormat
                && $0.format.isInterleaved == first.format.isInterleaved
        }) else {
            throw AudioRecordingError.formatChanged
        }

        let totalFrames = buffers.reduce(UInt64(0)) {
            $0 + UInt64($1.frameLength)
        }
        guard totalFrames <= UInt64(AVAudioFrameCount.max),
              let output = AVAudioPCMBuffer(
                pcmFormat: first.format,
                frameCapacity: AVAudioFrameCount(totalFrames)
              ),
              let outputChannels = output.floatChannelData
        else {
            throw AudioRecordingError.cannotAllocateBuffer
        }
        output.frameLength = AVAudioFrameCount(totalFrames)

        var frameOffset = 0
        for buffer in buffers {
            guard let channels = buffer.floatChannelData else {
                throw AudioRecordingError.formatChanged
            }
            let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(
                    outputChannels[channel].advanced(by: frameOffset),
                    channels[channel],
                    byteCount
                )
            }
            frameOffset += Int(buffer.frameLength)
        }
        return output
    }

    func reset() {
        lock.lock()
        buffers.removeAll()
        frameCount = 0
        lock.unlock()
    }
}
