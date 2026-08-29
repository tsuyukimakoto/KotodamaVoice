import Foundation
import KotodamaCore
import Testing
@testable import KotodamaVoice

@Test @MainActor
func modelWorkerUnloaderRoutesPurposeAndModelID() async throws {
    let speechWorker = ModelUnloadWorkerSpy()
    let formatterWorker = ModelUnloadWorkerSpy()
    let unloader = XPCModelWorkerUnloader(
        speechClient: SpeechWorkerClient(worker: speechWorker),
        formatterWorker: formatterWorker
    )
    let speech = modelEntry(id: "speech", purpose: .speech)
    let formatter = modelEntry(id: "formatter", purpose: .formatter)

    try await unloader.unload(speech)
    try await unloader.unload(formatter)

    #expect(speechWorker.requests.map(\.modelID) == [speech.id])
    #expect(formatterWorker.requests.map(\.modelID) == [formatter.id])
    #expect(speechWorker.requests.allSatisfy { $0.operation == .unloadModel })
    #expect(formatterWorker.requests.allSatisfy { $0.operation == .unloadModel })
}

@Test @MainActor
func modelWorkerUnloaderReportsWorkerFailure() async {
    let speechWorker = ModelUnloadWorkerSpy()
    speechWorker.failure = WorkerFailure(
        code: .processingFailed,
        isRetryable: true
    )
    let unloader = XPCModelWorkerUnloader(
        speechClient: SpeechWorkerClient(worker: speechWorker),
        formatterWorker: ModelUnloadWorkerSpy()
    )

    await #expect(
        throws: ModelWorkerUnloadError.workerFailure(.processingFailed)
    ) {
        try await unloader.unload(modelEntry(id: "speech", purpose: .speech))
    }
}

@Test @MainActor
func modelWorkerUnloaderUsesTheSharedFormatterClient() async throws {
    let clientWorker = ModelUnloadWorkerSpy()
    let fallbackWorker = ModelUnloadWorkerSpy()
    let formatterClient = FormatterWorkerClient(worker: clientWorker)
    let unloader = XPCModelWorkerUnloader(
        formatterClient: formatterClient,
        formatterWorker: fallbackWorker
    )
    let formatter = modelEntry(id: "formatter", purpose: .formatter)

    try await unloader.unload(formatter)

    #expect(clientWorker.requests.map(\.modelID) == [formatter.id])
    #expect(clientWorker.requests.map(\.operation) == [.unloadModel])
    #expect(fallbackWorker.requests.isEmpty)
}

@MainActor
private final class ModelUnloadWorkerSpy: WorkerRequestPerforming {
    var failure: WorkerFailure?
    private(set) var requests: [WorkerRequest] = []

    func perform(
        _ request: WorkerRequest,
        timeout: Duration
    ) async throws -> WorkerReply {
        requests.append(request)
        return WorkerReply(requestID: request.requestID, failure: failure)
    }
}

private func modelEntry(
    id: String,
    purpose: ModelPurpose
) -> ModelManifestEntry {
    ModelManifestEntry(
        id: id,
        displayName: id,
        purpose: purpose,
        version: "1",
        sourceURL: URL(string: "https://example.com/\(id).bin")!,
        revision: String(repeating: "a", count: 40),
        fileName: "\(id).bin",
        byteCount: 1,
        sha256: String(repeating: "b", count: 64),
        licenseName: "MIT",
        licenseFile: "MIT-LICENSE.txt",
        licenseURL: URL(string: "https://example.com/license")!,
        runtime: purpose == .speech ? .whisper : .llama
    )
}
