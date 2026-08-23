import Foundation
import KotodamaCore
import Testing
@testable import KotodamaVoice

@Test @MainActor
func speechClientLoadsOnceThenTranscribesWithOriginalRequestID() async throws {
    let worker = WorkerRequestPerformerSpy()
    let client = SpeechWorkerClient(worker: worker)
    let requestID = PipelineRequestID()
    let audioInput = WorkerAudioInput(
        fileHandle: FileHandle.nullDevice,
        sampleRate: 16_000,
        channelCount: 1,
        sampleCount: 1
    )
    worker.replies = [
        WorkerReply(requestID: PipelineRequestID()),
        WorkerReply(requestID: requestID, payload: Data("テスト".utf8)),
        WorkerReply(requestID: PipelineRequestID(), payload: Data("二回目".utf8)),
    ]

    let first = try await client.transcribe(
        modelID: "speech-model",
        audioInput: audioInput,
        requestID: requestID
    )
    let secondID = PipelineRequestID()
    worker.replies[0] = WorkerReply(
        requestID: secondID,
        payload: Data("二回目".utf8)
    )
    let second = try await client.transcribe(
        modelID: "speech-model",
        audioInput: audioInput,
        requestID: secondID
    )

    #expect(first == "テスト")
    #expect(second == "二回目")
    #expect(worker.requests.map(\.operation) == [
        .loadModel, .transcribe, .transcribe,
    ])
    #expect(worker.requests[1].requestID == requestID)
    #expect(worker.requests[2].requestID == secondID)
}

@Test @MainActor
func speechClientDoesNotFallbackAfterWorkerFailure() async throws {
    let worker = WorkerRequestPerformerSpy()
    let client = SpeechWorkerClient(worker: worker)
    let requestID = PipelineRequestID()
    worker.replies = [
        WorkerReply(requestID: PipelineRequestID()),
        WorkerReply(
            requestID: requestID,
            failure: WorkerFailure(
                code: .processingFailed,
                isRetryable: true
            )
        ),
    ]

    await #expect(
        throws: SpeechWorkerClientError.workerFailure(.processingFailed)
    ) {
        try await client.transcribe(
            modelID: "speech-model",
            audioInput: WorkerAudioInput(
                fileHandle: FileHandle.nullDevice,
                sampleRate: 16_000,
                channelCount: 1,
                sampleCount: 1
            ),
            requestID: requestID
        )
    }
    #expect(worker.requests.map(\.operation) == [.loadModel, .transcribe])
}

@Test @MainActor
func speechClientReloadsModelAfterConnectionInterruption() async throws {
    let worker = RecoveringWorkerRequestPerformerSpy()
    let client = SpeechWorkerClient(worker: worker)
    let audioInput = WorkerAudioInput(
        fileHandle: FileHandle.nullDevice,
        sampleRate: 16_000,
        channelCount: 1,
        sampleCount: 1
    )
    worker.results = [
        .success(WorkerReply(requestID: PipelineRequestID())),
        .failure(WorkerConnectionError.interrupted),
        .success(WorkerReply(requestID: PipelineRequestID())),
        .success(WorkerReply(
            requestID: PipelineRequestID(),
            payload: Data("recovered".utf8)
        )),
    ]

    await #expect(throws: WorkerConnectionError.interrupted) {
        try await client.transcribe(
            modelID: "speech-model",
            audioInput: audioInput,
            requestID: PipelineRequestID()
        )
    }
    let recovered = try await client.transcribe(
        modelID: "speech-model",
        audioInput: audioInput,
        requestID: PipelineRequestID()
    )

    #expect(recovered == "recovered")
    #expect(worker.requests.map(\.operation) == [
        .loadModel,
        .transcribe,
        .loadModel,
        .transcribe,
    ])
}

@Test @MainActor
func speechClientLoadsAgainAfterModelDeletionUnload() async throws {
    let worker = WorkerRequestPerformerSpy()
    let client = SpeechWorkerClient(worker: worker)
    let audioInput = WorkerAudioInput(
        fileHandle: FileHandle.nullDevice,
        sampleRate: 16_000,
        channelCount: 1,
        sampleCount: 1
    )
    worker.replies = [
        WorkerReply(requestID: PipelineRequestID()),
        WorkerReply(requestID: PipelineRequestID(), payload: Data("first".utf8)),
        WorkerReply(requestID: PipelineRequestID()),
        WorkerReply(requestID: PipelineRequestID()),
        WorkerReply(requestID: PipelineRequestID(), payload: Data("second".utf8)),
    ]

    _ = try await client.transcribe(
        modelID: "speech-model",
        audioInput: audioInput,
        requestID: PipelineRequestID()
    )
    try await client.unloadForDeletion(modelID: "speech-model")
    _ = try await client.transcribe(
        modelID: "speech-model",
        audioInput: audioInput,
        requestID: PipelineRequestID()
    )

    #expect(worker.requests.map(\.operation) == [
        .loadModel,
        .transcribe,
        .unloadModel,
        .loadModel,
        .transcribe,
    ])
    #expect(worker.requests[2].modelID == "speech-model")
}

@MainActor
private final class WorkerRequestPerformerSpy: WorkerRequestPerforming {
    var replies: [WorkerReply] = []
    private(set) var requests: [WorkerRequest] = []

    func perform(
        _ request: WorkerRequest,
        timeout: Duration
    ) async throws -> WorkerReply {
        requests.append(request)
        return replies.removeFirst()
    }
}

@MainActor
private final class RecoveringWorkerRequestPerformerSpy: WorkerRequestPerforming {
    var results: [Result<WorkerReply, Error>] = []
    private(set) var requests: [WorkerRequest] = []

    func perform(
        _ request: WorkerRequest,
        timeout: Duration
    ) async throws -> WorkerReply {
        requests.append(request)
        return try results.removeFirst().get()
    }
}
