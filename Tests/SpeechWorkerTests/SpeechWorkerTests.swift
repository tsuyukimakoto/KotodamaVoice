import Foundation
import KotodamaCore
import Testing

@Test func speechRuntimeLoadsAndUnloadsModel() throws {
    let backend = FixtureWhisperBackend()
    let modelURL = URL(fileURLWithPath: "/fixture/model.bin")
    let runtime = SpeechRuntime(
        backend: backend,
        resolveModelURL: { modelID in
            #expect(modelID == "speech-model")
            return modelURL
        }
    )

    try runtime.load(modelID: "speech-model")
    runtime.unload()

    #expect(backend.loadedURLs == [modelURL])
    #expect(backend.unloadedModelCount == 1)
}

@Test func speechRuntimeReadsFloat32AudioAndTranscribesInJapanese() throws {
    let backend = FixtureWhisperBackend()
    backend.result = .success("音声入力です")
    let runtime = SpeechRuntime(
        backend: backend,
        resolveModelURL: { _ in URL(fileURLWithPath: "/fixture/model.bin") }
    )
    try runtime.load(modelID: "speech-model")
    let fixture = try AudioInputFixture(samples: [0.25, -0.5, 0.75])

    let text = try runtime.transcribe(
        audioInput: fixture.input,
        requestID: PipelineRequestID()
    )

    #expect(text == "音声入力です")
    #expect(backend.receivedSamples == [0.25, -0.5, 0.75])
    #expect(backend.receivedLanguage == "ja")
}

@Test func pinnedWhisperRuntimeTranscribesKnownAudio() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let modelURL = projectRoot.appending(
        path: ".build/test-fixtures/ggml-tiny.en-q5_1.bin"
    )
    let audioURL = projectRoot.appending(
        path: ".build/runtimes/sources/whisper/samples/jfk.wav"
    )
    let runtime = SpeechRuntime(
        resolveModelURL: { _ in modelURL },
        language: "en"
    )
    let service = WorkerService(runtime: runtime)
    let fixture = try AudioInputFixture(samples: readPCM16Wave(at: audioURL))
    var loadReply: WorkerReply?
    service.perform(
        WorkerRequest(
            requestID: PipelineRequestID(),
            operation: .loadModel,
            modelID: "whisper-tiny-en-q5-1-fixture"
        )
    ) { loadReply = $0 }
    #expect(loadReply?.failure == nil)

    var transcriptionReply: WorkerReply?
    service.perform(
        WorkerRequest(
            requestID: PipelineRequestID(),
            operation: .transcribe,
            audioInput: fixture.input
        )
    ) { transcriptionReply = $0 }
    let text = String(
        data: try #require(transcriptionReply?.payload),
        encoding: .utf8
    )

    #expect(
        text == "And so my fellow Americans ask not what your country can do for you. Ask what you can do for your country."
    )
    var unloadReply: WorkerReply?
    service.perform(
        WorkerRequest(
            requestID: PipelineRequestID(),
            operation: .unloadModel,
            modelID: "whisper-tiny-en-q5-1-fixture"
        )
    ) { unloadReply = $0 }
    #expect(unloadReply?.failure == nil)
}

@Test func speechRuntimeRejectsMismatchedAudioMetadata() throws {
    let backend = FixtureWhisperBackend()
    let runtime = SpeechRuntime(
        backend: backend,
        resolveModelURL: { _ in URL(fileURLWithPath: "/fixture/model.bin") }
    )
    try runtime.load(modelID: "speech-model")
    let fixture = try AudioInputFixture(samples: [0.25], sampleCount: 2)

    #expect(throws: WorkerRuntimeError.invalidInput) {
        try runtime.transcribe(
            audioInput: fixture.input,
            requestID: PipelineRequestID()
        )
    }
}

@Test func speechRuntimeCancelsSpecificRequest() async throws {
    let backend = FixtureWhisperBackend()
    backend.waitForCancellation = true
    let runtime = SpeechRuntime(
        backend: backend,
        resolveModelURL: { _ in URL(fileURLWithPath: "/fixture/model.bin") }
    )
    try runtime.load(modelID: "speech-model")
    let fixture = try AudioInputFixture(samples: [0.25])
    let requestID = PipelineRequestID()

    let transcription = Task.detached {
        try runtime.transcribe(audioInput: fixture.input, requestID: requestID)
    }
    #expect(await backend.waitUntilStarted())
    runtime.cancel(requestID: requestID)

    await #expect(throws: WorkerRuntimeError.cancelled) {
        try await transcription.value
    }
}

@Test func speechRuntimeCancelAllStopsActiveRequestBeforeUnload() async throws {
    let backend = FixtureWhisperBackend()
    backend.waitForCancellation = true
    let runtime = SpeechRuntime(
        backend: backend,
        resolveModelURL: { _ in URL(fileURLWithPath: "/fixture/model.bin") }
    )
    try runtime.load(modelID: "speech-model")
    let fixture = try AudioInputFixture(samples: [0.25])

    let transcription = Task.detached {
        try runtime.transcribe(
            audioInput: fixture.input,
            requestID: PipelineRequestID()
        )
    }
    #expect(await backend.waitUntilStarted())
    runtime.cancelAll()

    await #expect(throws: WorkerRuntimeError.cancelled) {
        try await transcription.value
    }
    runtime.unload()
    #expect(backend.unloadedModelCount == 1)
}

@Test func workerServiceDeliversCancellationWhileTranscriptionIsRunning() async throws {
    let backend = FixtureWhisperBackend()
    backend.waitForCancellation = true
    let runtime = SpeechRuntime(
        backend: backend,
        resolveModelURL: { _ in URL(fileURLWithPath: "/fixture/model.bin") }
    )
    let service = WorkerService(runtime: runtime)
    let serviceBox = UncheckedSendableBox(service)
    let fixture = try AudioInputFixture(samples: [0.25])
    let requestID = PipelineRequestID()
    service.perform(
        WorkerRequest(
            requestID: PipelineRequestID(),
            operation: .loadModel,
            modelID: "speech-model"
        )
    ) { reply in
        #expect(reply.failure == nil)
    }

    let transcription = Task.detached {
        await withCheckedContinuation { continuation in
            serviceBox.value.perform(
                WorkerRequest(
                    requestID: requestID,
                    operation: .transcribe,
                    audioInput: fixture.input
                )
            ) { reply in
                continuation.resume(returning: reply)
            }
        }
    }
    #expect(await backend.waitUntilStarted())

    service.perform(
        WorkerRequest(requestID: requestID, operation: .cancel)
    ) { reply in
        #expect(reply.failure == nil)
    }

    let reply = await transcription.value
    #expect(reply.failure?.code == .cancelled)
}

private final class FixtureWhisperBackend: WhisperBackend, @unchecked Sendable {
    var result: Result<String, Error> = .success("fixture")
    var waitForCancellation = false
    private let lock = NSLock()
    private var hasStarted = false
    private(set) var loadedURLs: [URL] = []
    private(set) var unloadedModelCount = 0
    private(set) var receivedSamples: [Float] = []
    private(set) var receivedLanguage: String?

    func loadModel(at url: URL) throws -> AnyObject {
        loadedURLs.append(url)
        return FixtureModel()
    }

    func transcribe(
        model: AnyObject,
        samples: [Float],
        language: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> String {
        receivedSamples = samples
        receivedLanguage = language
        lock.lock()
        hasStarted = true
        lock.unlock()
        if waitForCancellation {
            while !isCancelled() {
                Thread.sleep(forTimeInterval: 0.001)
            }
            throw WorkerRuntimeError.cancelled
        }
        return try result.get()
    }

    func unloadModel(_ model: AnyObject) {
        unloadedModelCount += 1
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<1_000 {
            if isStarted { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasStarted
    }
}

private final class FixtureModel {}

private final class AudioInputFixture: @unchecked Sendable {
    let input: WorkerAudioInput
    private let url: URL

    init(samples: [Float], sampleCount: Int64? = nil) throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        let data = samples.withUnsafeBytes { Data($0) }
        try data.write(to: url, options: .atomic)
        input = WorkerAudioInput(
            fileHandle: try FileHandle(forReadingFrom: url),
            sampleRate: 16_000,
            channelCount: 1,
            sampleCount: sampleCount ?? Int64(samples.count)
        )
    }

    deinit {
        try? input.fileHandle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

private func readPCM16Wave(at url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count >= 12,
          String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
          String(decoding: data[8..<12], as: UTF8.self) == "WAVE"
    else {
        throw WorkerRuntimeError.invalidInput
    }

    var cursor = 12
    var formatIsPCM16Mono16K = false
    var audioData: Data?
    while cursor + 8 <= data.count {
        let identifier = String(
            decoding: data[cursor..<(cursor + 4)],
            as: UTF8.self
        )
        let byteCount = Int(readUInt32(data, at: cursor + 4))
        let start = cursor + 8
        let end = start + byteCount
        guard end <= data.count else {
            throw WorkerRuntimeError.invalidInput
        }
        if identifier == "fmt ", byteCount >= 16 {
            formatIsPCM16Mono16K = readUInt16(data, at: start) == 1
                && readUInt16(data, at: start + 2) == 1
                && readUInt32(data, at: start + 4) == 16_000
                && readUInt16(data, at: start + 14) == 16
        } else if identifier == "data" {
            audioData = Data(data[start..<end])
        }
        cursor = end + byteCount % 2
    }
    guard formatIsPCM16Mono16K, let audioData,
          audioData.count.isMultiple(of: 2)
    else {
        throw WorkerRuntimeError.invalidInput
    }

    return stride(from: 0, to: audioData.count, by: 2).map { offset in
        let sample = Int16(bitPattern: readUInt16(audioData, at: offset))
        return Float(sample) / 32_768
    }
}

private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
