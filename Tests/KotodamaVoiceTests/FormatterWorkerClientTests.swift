import Foundation
import KotodamaCore
import Testing
@testable import KotodamaVoice

@Test @MainActor
func formatterWorkerClientLoadsOnceAndUsesTheActivePrompt() async throws {
    let worker = FormatterWorkerPerformerSpy(results: [
        .success(WorkerReply(requestID: PipelineRequestID())),
        .success(WorkerReply(requestID: PipelineRequestID(), payload: Data("整形結果1".utf8))),
        .success(WorkerReply(requestID: PipelineRequestID(), payload: Data("整形結果2".utf8))),
    ])
    let promptState = FormatterPromptFixture(value: "Default Prompt")
    let client = FormatterWorkerClient(
        worker: worker,
        modelID: { "formatter-model" },
        prompt: { promptState.value }
    )

    let first = try await client.format("原文1", requestID: PipelineRequestID())
    promptState.value = "Custom Prompt"
    let second = try await client.format("原文2", requestID: PipelineRequestID())

    #expect(first == "整形結果1")
    #expect(second == "整形結果2")
    #expect(worker.requests.map(\.operation) == [.loadModel, .format, .format])
    #expect(worker.requests[0].modelID == "formatter-model")
    #expect(worker.requests[1].options == [
        "text": "原文1",
        "prompt": "Default Prompt",
    ])
    #expect(worker.requests[2].options == [
        "text": "原文2",
        "prompt": "Custom Prompt",
    ])
}

@Test @MainActor
func formatterWorkerFailureFallsBackWithoutCallingTheOtherFormatter() async throws {
    let requestID = PipelineRequestID()
    let worker = FormatterWorkerPerformerSpy(results: [
        .success(WorkerReply(requestID: PipelineRequestID())),
        .success(WorkerReply(
            requestID: requestID,
            failure: WorkerFailure(
                code: .processingFailed,
                isRetryable: true
            )
        )),
    ])
    let builtIn = FormatterWorkerClient(
        worker: worker,
        modelID: { "formatter-model" },
        prompt: { "Default Prompt" }
    )
    let external = FormatterWorkerTextSpy()
    let store = PipelineStore(initialState: .transcribing(requestID))
    let pipeline = TextFormattingPipeline(
        coordinator: PipelineCoordinator(store: store),
        settings: FormatterSettingsStore(engine: .builtIn),
        builtIn: builtIn,
        external: external
    )

    let output = try await pipeline.process(
        LocalTranscription(requestID: requestID, text: "原文")
    )

    #expect(output == FormattingOutput(text: "原文", usedFallback: true))
    #expect(worker.requests.map(\.operation) == [.loadModel, .format])
    #expect(external.callCount == 0)
    #expect(store.state == .outputting(requestID))
}

@Test @MainActor
func formatterWorkerTimeoutCancelsTheRequestAndFallsBack() async throws {
    let requestID = PipelineRequestID()
    let transport = FormatterTimeoutTransport()
    let client = FormatterWorkerClient(
        worker: WorkerConnectionManager(makeTransport: { transport }),
        formattingTimeout: .milliseconds(20),
        modelID: { "formatter-model" },
        prompt: { "Default Prompt" }
    )
    let external = FormatterWorkerTextSpy()
    let store = PipelineStore(initialState: .transcribing(requestID))
    let pipeline = TextFormattingPipeline(
        coordinator: PipelineCoordinator(store: store),
        settings: FormatterSettingsStore(engine: .builtIn),
        builtIn: client,
        external: external
    )

    let output = try await pipeline.process(
        LocalTranscription(requestID: requestID, text: "原文")
    )

    #expect(output == FormattingOutput(text: "原文", usedFallback: true))
    #expect(transport.operations == [.loadModel, .format])
    #expect(transport.cancelledRequestIDs == [requestID])
    #expect(external.callCount == 0)
    #expect(store.state == .outputting(requestID))
}

@MainActor
private final class FormatterWorkerPerformerSpy: WorkerRequestPerforming {
    private var results: [Result<WorkerReply, Error>]
    private(set) var requests: [WorkerRequest] = []

    init(results: [Result<WorkerReply, Error>]) {
        self.results = results
    }

    func perform(
        _ request: WorkerRequest,
        timeout: Duration
    ) async throws -> WorkerReply {
        requests.append(request)
        let result = results.removeFirst()
        switch result {
        case let .success(reply):
            return WorkerReply(
                protocolVersion: reply.protocolVersion,
                requestID: request.requestID,
                payload: reply.payload,
                failure: reply.failure
            )
        case let .failure(error):
            throw error
        }
    }
}

@MainActor
private final class FormatterWorkerTextSpy: TextFormatting {
    private(set) var callCount = 0

    func format(
        _ text: String,
        requestID: PipelineRequestID
    ) async throws -> String {
        callCount += 1
        return text
    }
}

@MainActor
private final class FormatterTimeoutTransport: WorkerTransport {
    var interruptionHandler: (@MainActor () -> Void)?
    var invalidationHandler: (@MainActor () -> Void)?
    private(set) var operations: [WorkerOperation] = []
    private(set) var cancelledRequestIDs: [PipelineRequestID] = []

    func activate() {}

    func send(
        _ request: WorkerRequest,
        reply: @escaping @MainActor (WorkerReply) -> Void
    ) {
        operations.append(request.operation)
        if request.operation == .loadModel {
            reply(WorkerReply(requestID: request.requestID))
        }
    }

    func cancel(requestID: PipelineRequestID) {
        cancelledRequestIDs.append(requestID)
    }

    func invalidate() {}
}

@MainActor
private final class FormatterPromptFixture {
    var value: String

    init(value: String) {
        self.value = value
    }
}
