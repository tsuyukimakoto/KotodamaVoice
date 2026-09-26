import AVFoundation
import KotodamaCore

@MainActor
protocol AudioRecordingManaging: AnyObject {
    func start() throws
    func stop() throws -> AVAudioPCMBuffer
    func cancel()
}

extension AudioRecordingService: AudioRecordingManaging {}

@MainActor
protocol SpeechTranscribing: AnyObject {
    var glossaryEngine: String { get }
    func transcribe(
        modelID: String, audioInput: WorkerAudioInput, requestID: PipelineRequestID,
        hints: [SpeechGlossaryHint]
    ) async throws -> SpeechGlossaryResult

    func transcribe(
        modelID: String,
        audioInput: WorkerAudioInput,
        requestID: PipelineRequestID
    ) async throws -> String
}

extension SpeechTranscribing {
    var glossaryEngine: String { "builtIn" }
    func transcribe(
        modelID: String, audioInput: WorkerAudioInput, requestID: PipelineRequestID,
        hints: [SpeechGlossaryHint]
    ) async throws -> SpeechGlossaryResult {
        guard hints.isEmpty else { throw WorkerRuntimeError.invalidInput }
        return SpeechGlossaryResult(
            text: try await transcribe(
                modelID: modelID, audioInput: audioInput, requestID: requestID))
    }
}

extension SpeechWorkerClient: SpeechTranscribing {}

struct LocalTranscription: Equatable {
    let requestID: PipelineRequestID
    let text: String
}

@MainActor
final class LocalSpeechPipeline {
    private let store: PipelineStore
    private let coordinator: PipelineCoordinator
    private let recorder: AudioRecordingManaging
    private let temporaryAudioStore: TemporaryAudioStore
    private let speech: SpeechTranscribing
    private let glossary: GlossarySession?

    init(
        store: PipelineStore,
        coordinator: PipelineCoordinator,
        recorder: AudioRecordingManaging,
        temporaryAudioStore: TemporaryAudioStore,
        speech: SpeechTranscribing,
        glossary: GlossarySession? = nil
    ) {
        self.store = store
        self.coordinator = coordinator
        self.recorder = recorder
        self.temporaryAudioStore = temporaryAudioStore
        self.speech = speech
        self.glossary = glossary
    }

    func startRecording() throws {
        try recorder.start()
        glossary?.begin()
    }

    func stopAndTranscribe(modelID: String) async throws -> LocalTranscription {
        let recording: AVAudioPCMBuffer
        do {
            recording = try recorder.stop()
        } catch {
            cancelRecording()
            throw error
        }

        let requestID = try coordinator.stopRecording()
        let snapshot = glossary?.snapshot
        let engine = speech.glossaryEngine
        let entries = snapshot?.document.entries ?? []
        let effective: GlossaryEffective =
            snapshot?.speech != true
            ? .disabled
            : engine != "builtIn" ? .unsupported : entries.isEmpty ? .empty : .applied
        let hints = effective == .applied ? entries.map(SpeechGlossaryHint.init) : []

        do {
            let lease = try temporaryAudioStore.createLease(
                requestID: requestID,
                buffer: recording
            )
            defer { lease.release() }
            let result = try await speech.transcribe(
                modelID: modelID,
                audioInput: lease.audioInput,
                requestID: requestID,
                hints: hints
            )
            glossary?.record(
                requestID: requestID, stage: .speech, status: .success, text: result.text,
                effective: effective, engine: engine, modelID: modelID.isEmpty ? nil : modelID,
                submitted: result.submittedEntryIDs)
            return LocalTranscription(requestID: requestID, text: result.text)

        } catch is CancellationError {
            recordFailure(requestID, error: CancellationError(), engine: engine)
            completeCancellation(requestID: requestID)
            throw CancellationError()
        } catch {
            recordFailure(requestID, error: error, engine: engine)
            _ = try? coordinator.fail(requestID: requestID)
            throw error
        }
    }

    func recordingDidFail(_: Error) {
        cancelRecording()
    }

    func cancelRecording() {
        recorder.cancel()
        glossary?.finish()
        guard store.state == .recording else { return }
        do {
            _ = try coordinator.cancel()
            _ = try coordinator.completeCancellation(requestID: nil)
        } catch {
            _ = try? coordinator.fail(requestID: nil)
        }
    }

    private func recordFailure(_ id: PipelineRequestID, error: Error, engine: String) {
        let cancelled =
            error is CancellationError
            || (error as? SpeechWorkerClientError) == .workerFailure(.cancelled)
        let timedOut =
            (error as? WorkerConnectionError) == .timedOut
            || (error as? SpeechWorkerClientError) == .workerFailure(.timedOut)
            || (error as? URLError)?.code == .timedOut

        glossary?.record(
            requestID: id, stage: .speech, status: cancelled ? .cancelled : .failed,
            text: nil, effective: .unknown, engine: engine,
            reason: cancelled ? .cancelled : timedOut ? .timedOut : .processingFailed)
        glossary?.record(
            requestID: id, stage: .formatting, status: .notRun, text: nil, effective: .notRun)
        glossary?.finish()
    }

    private func completeCancellation(requestID: PipelineRequestID) {
        do {
            _ = try coordinator.cancel()
            _ = try coordinator.completeCancellation(requestID: requestID)
        } catch {
            _ = try? coordinator.fail(requestID: requestID)
        }
    }
}
