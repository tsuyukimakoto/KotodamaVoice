import Foundation
import KotodamaCore
import whisper

protocol WhisperBackend: AnyObject {
    func loadModel(at url: URL) throws -> AnyObject
    func transcribe(
        model: AnyObject,
        samples: [Float],
        language: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> String
    func unloadModel(_ model: AnyObject)
}

final class SpeechRuntime: SpeechTranscribingRuntime, @unchecked Sendable {
    private let condition = NSCondition()
    private let backend: WhisperBackend
    private let resolveModelURL: (String) throws -> URL
    private var model: AnyObject?
    private var cancelledRequestIDs = Set<PipelineRequestID>()
    private var activeRequestIDs = Set<PipelineRequestID>()

    init(
        backend: WhisperBackend = CWhisperBackend(),
        resolveModelURL: @escaping (String) throws -> URL
    ) {
        self.backend = backend
        self.resolveModelURL = resolveModelURL
    }

    func load(modelID: String) throws {
        let newModel = try backend.loadModel(at: resolveModelURL(modelID))
        condition.lock()
        cancelledRequestIDs.formUnion(activeRequestIDs)
        while !activeRequestIDs.isEmpty {
            condition.wait()
        }
        let oldModel = model
        model = newModel
        cancelledRequestIDs.removeAll()
        condition.unlock()
        if let oldModel {
            backend.unloadModel(oldModel)
        }
    }

    func transcribe(
        audioInput: WorkerAudioInput,
        requestID: PipelineRequestID
    ) throws -> String {
        guard audioInput.sampleRate == 16_000,
              audioInput.channelCount == 1,
              audioInput.sampleCount > 0
        else {
            throw WorkerRuntimeError.invalidInput
        }
        try audioInput.fileHandle.seek(toOffset: 0)
        let data = try audioInput.fileHandle.readToEnd() ?? Data()
        let expectedBytes = Int(audioInput.sampleCount) * MemoryLayout<Float>.size
        guard data.count == expectedBytes else {
            throw WorkerRuntimeError.invalidInput
        }

        condition.lock()
        guard let model else {
            condition.unlock()
            throw WorkerRuntimeError.processingFailed
        }
        guard activeRequestIDs.isEmpty else {
            condition.unlock()
            throw WorkerRuntimeError.processingFailed
        }
        activeRequestIDs.insert(requestID)
        let wasAlreadyCancelled = cancelledRequestIDs.contains(requestID)
        condition.unlock()

        if wasAlreadyCancelled {
            finish(requestID: requestID)
            throw WorkerRuntimeError.cancelled
        }

        let samples = data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
        defer {
            finish(requestID: requestID)
        }
        return try backend.transcribe(
            model: model,
            samples: samples,
            language: "ja",
            isCancelled: { [weak self] in
                self?.isCancelled(requestID) ?? true
            }
        )
    }

    func cancel(requestID: PipelineRequestID) {
        condition.lock()
        cancelledRequestIDs.insert(requestID)
        condition.unlock()
    }

    func cancelAll() {
        condition.lock()
        cancelledRequestIDs.formUnion(activeRequestIDs)
        condition.unlock()
    }

    func unload() {
        condition.lock()
        cancelledRequestIDs.formUnion(activeRequestIDs)
        while !activeRequestIDs.isEmpty {
            condition.wait()
        }
        let oldModel = model
        model = nil
        cancelledRequestIDs.removeAll()
        condition.unlock()
        if let oldModel {
            backend.unloadModel(oldModel)
        }
    }

    private func isCancelled(_ requestID: PipelineRequestID) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelledRequestIDs.contains(requestID)
    }

    private func finish(requestID: PipelineRequestID) {
        condition.lock()
        activeRequestIDs.remove(requestID)
        cancelledRequestIDs.remove(requestID)
        condition.broadcast()
        condition.unlock()
    }
}

enum SpeechRuntimeBackendError: Error {
    case modelLoadFailed
    case invalidModelHandle
    case inferenceFailed(Int32)
}

final class CWhisperBackend: WhisperBackend {
    func loadModel(at url: URL) throws -> AnyObject {
        var params = whisper_context_default_params()
        params.use_gpu = true
        let context = url.path.withCString {
            whisper_init_from_file_with_params($0, params)
        }
        guard let context else {
            throw SpeechRuntimeBackendError.modelLoadFailed
        }
        return WhisperContextHandle(context: context)
    }

    func transcribe(
        model: AnyObject,
        samples: [Float],
        language: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> String {
        guard let handle = model as? WhisperContextHandle,
              let context = handle.context
        else {
            throw SpeechRuntimeBackendError.invalidModelHandle
        }
        let cancellation = WhisperCancellation(isCancelled: isCancelled)
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(min(ProcessInfo.processInfo.activeProcessorCount, 8))
        params.translate = false
        params.no_context = true
        params.no_timestamps = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.abort_callback = { userData in
            guard let userData else { return true }
            return Unmanaged<WhisperCancellation>
                .fromOpaque(userData)
                .takeUnretainedValue()
                .isCancelled()
        }
        params.abort_callback_user_data = Unmanaged
            .passUnretained(cancellation)
            .toOpaque()

        let result = language.withCString { languagePointer in
            params.language = languagePointer
            return samples.withUnsafeBufferPointer { samplesPointer in
                whisper_full(
                    context,
                    params,
                    samplesPointer.baseAddress,
                    Int32(samplesPointer.count)
                )
            }
        }
        guard result == 0 else {
            if isCancelled() {
                throw WorkerRuntimeError.cancelled
            }
            throw SpeechRuntimeBackendError.inferenceFailed(result)
        }

        var text = ""
        for segment in 0..<whisper_full_n_segments(context) {
            guard let segmentText = whisper_full_get_segment_text(
                context,
                segment
            ) else {
                continue
            }
            text += String(cString: segmentText)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unloadModel(_ model: AnyObject) {
        (model as? WhisperContextHandle)?.releaseContext()
    }
}

private final class WhisperContextHandle {
    fileprivate private(set) var context: OpaquePointer?

    init(context: OpaquePointer) {
        self.context = context
    }

    func releaseContext() {
        guard let context else { return }
        self.context = nil
        whisper_free(context)
    }

    deinit {
        releaseContext()
    }
}

private final class WhisperCancellation: @unchecked Sendable {
    let isCancelled: @Sendable () -> Bool

    init(isCancelled: @escaping @Sendable () -> Bool) {
        self.isCancelled = isCancelled
    }
}
