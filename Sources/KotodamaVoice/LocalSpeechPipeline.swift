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
    func transcribe(
        modelID: String,
        audioInput: WorkerAudioInput,
        requestID: PipelineRequestID
    ) async throws -> String
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

    init(
        store: PipelineStore,
        coordinator: PipelineCoordinator,
        recorder: AudioRecordingManaging,
        temporaryAudioStore: TemporaryAudioStore,
        speech: SpeechTranscribing
    ) {
        self.store = store
        self.coordinator = coordinator
        self.recorder = recorder
        self.temporaryAudioStore = temporaryAudioStore
        self.speech = speech
    }

    func startRecording() throws {
        try recorder.start()
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
        do {
            let lease = try temporaryAudioStore.createLease(
                requestID: requestID,
                buffer: recording
            )
            defer { lease.release() }
            let text = try await speech.transcribe(
                modelID: modelID,
                audioInput: lease.audioInput,
                requestID: requestID
            )
            return LocalTranscription(requestID: requestID, text: text)
        } catch is CancellationError {
            completeCancellation(requestID: requestID)
            throw CancellationError()
        } catch {
            _ = try? coordinator.fail(requestID: requestID)
            throw error
        }
    }

    func recordingDidFail(_: Error) {
        cancelRecording()
    }

    func cancelRecording() {
        recorder.cancel()
        guard store.state == .recording else { return }
        do {
            _ = try coordinator.cancel()
            _ = try coordinator.completeCancellation(requestID: nil)
        } catch {
            _ = try? coordinator.fail(requestID: nil)
        }
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
