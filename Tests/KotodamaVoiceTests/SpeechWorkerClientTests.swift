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
