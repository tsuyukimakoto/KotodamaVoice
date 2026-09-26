import AVFoundation
import Foundation
import KotodamaCore
import Testing

@testable import KotodamaVoice

@Test(arguments: [SpeechEngine.builtIn, .external])
@MainActor
func selectedSpeechEngineUsesOnlyItsConfiguredTranscriber(
    engine: SpeechEngine
) async throws {
    let settings = SpeechSettingsStore(engine: engine)
    let builtIn = SpeechTranscriberSpy(outcome: .success)
    let external = SpeechTranscriberSpy(outcome: .success)
    let selected = SelectedSpeechTranscriber(
        settings: settings,
        builtIn: builtIn,
        external: external
    )

    _ = try await selected.transcribe(
        modelID: "built-in-model",
        audioInput: WorkerAudioInput(
            fileHandle: FileHandle.nullDevice,
            sampleRate: 16_000,
            channelCount: 1,
            sampleCount: 0
        ),
        requestID: PipelineRequestID()
    )

    #expect(builtIn.callCount == (engine == .builtIn ? 1 : 0))
    #expect(external.callCount == (engine == .external ? 1 : 0))
}

@Test @MainActor
func emptyRecordingDoesNotReachSpeechAndReturnsToReady() async throws {
    let fixture = try LocalSpeechPipelineFixture(
        stopResult: .failure(AudioRecordingError.emptyRecording)
    )

    await #expect(throws: AudioRecordingError.self) {
        try await fixture.pipeline.stopAndTranscribe(modelID: "speech-model")
    }

    #expect(fixture.store.state == .ready)
    #expect(fixture.recorder.cancelCount == 1)
    #expect(fixture.speech.callCount == 0)
}

@Test @MainActor
func recordingFailuresDiscardPartialAudioWithoutCallingSpeech() throws {
    for error in [
        AudioRecordingError.inputConfigurationChanged,
        AudioRecordingError.maximumDurationExceeded,
    ] {
        let fixture = try LocalSpeechPipelineFixture()

        fixture.pipeline.recordingDidFail(error)

        #expect(fixture.store.state == .ready)
        #expect(fixture.recorder.cancelCount == 1)
        #expect(fixture.speech.callCount == 0)
    }
}

@Test @MainActor
func recordingCancellationDiscardsPartialAudioWithoutCallingSpeech() throws {
    let fixture = try LocalSpeechPipelineFixture()

    fixture.pipeline.cancelRecording()

    #expect(fixture.store.state == .ready)
    #expect(fixture.recorder.cancelCount == 1)
    #expect(fixture.speech.callCount == 0)
}

@Test(arguments: SpeechOutcome.allCases)
@MainActor
func temporaryAudioIsRemovedAfterEverySpeechOutcome(
    outcome: SpeechOutcome
) async throws {
    let fixture = try LocalSpeechPipelineFixture(outcome: outcome)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    switch outcome {
    case .success:
        let transcription = try await fixture.pipeline.stopAndTranscribe(
            modelID: "speech-model"
        )
        #expect(transcription.requestID == fixture.requestID)
        #expect(transcription.text == "transcribed text")
        #expect(fixture.store.state == .transcribing(fixture.requestID))
    case .failure:
        await #expect(throws: SpeechTestError.self) {
            try await fixture.pipeline.stopAndTranscribe(
                modelID: "speech-model"
            )
        }
        #expect(fixture.store.state == .failed(fixture.requestID))
    case .cancellation:
        await #expect(throws: CancellationError.self) {
            try await fixture.pipeline.stopAndTranscribe(
                modelID: "speech-model"
            )
        }
        #expect(fixture.store.state == .ready)
    }

    #expect(fixture.speech.callCount == 1)
    #expect(fixture.speech.receivedByteCount == 16 * MemoryLayout<Float>.size)
    #expect(
        !FileManager.default.fileExists(
            atPath: fixture.requestDirectoryURL.path
        )
    )
}

enum SpeechOutcome: CaseIterable, CustomTestStringConvertible {
    case success
    case failure
    case cancellation

    var testDescription: String {
        switch self {
        case .success: "success"
        case .failure: "failure"
        case .cancellation: "cancellation"
        }
    }
}

private enum SpeechTestError: Error {
    case failed
}

@MainActor
private final class LocalSpeechPipelineFixture {
    let requestID = PipelineRequestID()
    let rootURL: URL
    let store: PipelineStore
    let recorder: AudioRecorderSpy
    let speech: SpeechTranscriberSpy
    let pipeline: LocalSpeechPipeline

    var requestDirectoryURL: URL {
        rootURL.appending(
            path: requestID.rawValue.uuidString,
            directoryHint: .isDirectory
        )
    }

    init(
        stopResult: Result<AVAudioPCMBuffer, Error>? = nil,
        outcome: SpeechOutcome = .success
    ) throws {
        rootURL = FileManager.default.temporaryDirectory.appending(
            path: "KotodamaVoicePipelineTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        store = PipelineStore(initialState: .recording)
        let coordinator = PipelineCoordinator(
            store: store,
            makeRequestID: { [requestID] in requestID }
        )
        let resolvedStopResult: Result<AVAudioPCMBuffer, Error>
        if let stopResult {
            resolvedStopResult = stopResult
        } else {
            resolvedStopResult = .success(try mono16kPipelineBuffer())
        }
        recorder = AudioRecorderSpy(stopResult: resolvedStopResult)
        speech = SpeechTranscriberSpy(outcome: outcome)
        pipeline = LocalSpeechPipeline(
            store: store,
            coordinator: coordinator,
            recorder: recorder,
            temporaryAudioStore: TemporaryAudioStore(rootURL: rootURL),
            speech: speech
        )
    }
}

@MainActor
private final class AudioRecorderSpy: AudioRecordingManaging {
    let stopResult: Result<AVAudioPCMBuffer, Error>
    private(set) var cancelCount = 0

    init(stopResult: Result<AVAudioPCMBuffer, Error>) {
        self.stopResult = stopResult
    }

    func start() throws {}

    func stop() throws -> AVAudioPCMBuffer {
        try stopResult.get()
    }

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
private final class SpeechTranscriberSpy: SpeechTranscribing {
    private let outcome: SpeechOutcome
    private(set) var callCount = 0
    private(set) var receivedByteCount = 0

    init(outcome: SpeechOutcome) {
        self.outcome = outcome
    }

    func transcribe(
        modelID: String,
        audioInput: WorkerAudioInput,
        requestID: PipelineRequestID
    ) async throws -> String {
        callCount += 1
        receivedByteCount = try audioInput.fileHandle.readToEnd()?.count ?? 0
        switch outcome {
        case .success:
            return "transcribed text"
        case .failure:
            throw SpeechTestError.failed
        case .cancellation:
            throw CancellationError()
        }
    }
}

private func mono16kPipelineBuffer() throws -> AVAudioPCMBuffer {
    let format = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
    )
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)
    )
    buffer.frameLength = 16
    return buffer
}

@Test(arguments: [SpeechOutcome.failure, .cancellation]) @MainActor
func glossarySpeechFailuresHaveNoCountsAndNeverRunFormatting(outcome: SpeechOutcome) async throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(
        UserDefaults(suiteName: "com.tsuyukimakoto.GlossarySpeechFailure.\(UUID())"))
    let settings = GlossarySettingsStore(directory: root, defaults: defaults)
    try settings.save(GlossaryEntry(term: "Codex"))
    settings.setDiagnostics(true)
    let session = GlossarySession(
        settings: settings,
        diagnostics: GlossaryDiagnostics(directory: root.appending(path: "logs")))
    let store = PipelineStore(initialState: .recording)
    let recorder = AudioRecorderSpy(stopResult: .success(try mono16kPipelineBuffer()))
    let pipeline = LocalSpeechPipeline(
        store: store, coordinator: PipelineCoordinator(store: store), recorder: recorder,
        temporaryAudioStore: TemporaryAudioStore(rootURL: root.appending(path: "audio")),
        speech: SpeechTranscriberSpy(outcome: outcome), glossary: session)
    try pipeline.startRecording()
    do {
        _ = try await pipeline.stopAndTranscribe(modelID: "fixture")
        Issue.record("Expected speech failure")
    } catch {}
    let log = try String(contentsOf: #require(session.diagnostics.currentFile), encoding: .utf8)
    let events = try log.split(separator: "\n").map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
    #expect(events.count == 2)
    #expect(events[0]["status"] as? String == (outcome == .cancellation ? "cancelled" : "failed"))
    #expect(events[1]["status"] as? String == "not_run")
    #expect(events.allSatisfy { $0["counts"] is NSNull })
    #expect(session.snapshot == nil)
}
