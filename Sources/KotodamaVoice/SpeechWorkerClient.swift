import Foundation
import KotodamaCore

enum SpeechWorkerClientError: Error, Equatable {
    case workerFailure(WorkerFailureCode)
    case missingPayload
    case invalidText
}

@MainActor
protocol WorkerRequestPerforming: AnyObject {
    func perform(
        _ request: WorkerRequest,
        timeout: Duration
    ) async throws -> WorkerReply
}

extension WorkerConnectionManager: WorkerRequestPerforming {}

@MainActor
final class SpeechWorkerClient {
    private let worker: WorkerRequestPerforming
    private let operationGate: ModelOperationGate
    private var loadedModelID: String?

    init(
        worker: WorkerRequestPerforming? = nil,
        operationGate: ModelOperationGate = ModelOperationGate()
    ) {
        self.operationGate = operationGate
        self.worker = worker ?? WorkerConnectionManager(
            makeTransport: {
                NSXPCWorkerTransport(
                    serviceName: WorkerEndpoint.speech.serviceName
                )
            },
            logger: OSLogDiagnosticLogger(component: .app)
        )
    }

    func transcribe(
        modelID: String,
        audioInput: WorkerAudioInput,
        requestID: PipelineRequestID
    ) async throws -> String {
        do {
            return try await operationGate.withOperation(for: modelID) {
                try await self.performTranscription(
                    modelID: modelID,
                    audioInput: audioInput,
                    requestID: requestID
                )
            }
        } catch let error as WorkerConnectionError {
            loadedModelID = nil
            throw error
        }
    }

    private func performTranscription(
        modelID: String,
        audioInput: WorkerAudioInput,
        requestID: PipelineRequestID
    ) async throws -> String {
        if loadedModelID != modelID {
            let loadReply = try await worker.perform(
                WorkerRequest(
                    requestID: PipelineRequestID(),
                    operation: .loadModel,
                    modelID: modelID
                ),
                timeout: .seconds(60)
            )
            try validate(loadReply)
            loadedModelID = modelID
        }

        let reply = try await worker.perform(
            WorkerRequest(
                requestID: requestID,
                operation: .transcribe,
                audioInput: audioInput
            ),
            timeout: .seconds(300)
        )
        try validate(reply)
        guard let payload = reply.payload else {
            throw SpeechWorkerClientError.missingPayload
        }
        guard let text = String(data: payload, encoding: .utf8) else {
            throw SpeechWorkerClientError.invalidText
        }
        return text
    }

    func unload() async throws {
        guard let loadedModelID else { return }
        try await operationGate.withOperation(for: loadedModelID) {
            try await self.unloadForDeletion(modelID: loadedModelID)
        }
    }

    func unloadForDeletion(modelID: String) async throws {
        let reply = try await worker.perform(
            WorkerRequest(
                requestID: PipelineRequestID(),
                operation: .unloadModel,
                modelID: modelID
            ),
            timeout: .seconds(30)
        )
        try validate(reply)
        if loadedModelID == modelID {
            loadedModelID = nil
        }
    }

    private func validate(_ reply: WorkerReply) throws {
        if let failure = reply.failure {
            throw SpeechWorkerClientError.workerFailure(failure.code)
        }
    }
}
