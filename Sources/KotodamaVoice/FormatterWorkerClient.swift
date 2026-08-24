import Foundation
import KotodamaCore

enum FormatterWorkerClientError: Error, Equatable {
    case modelUnavailable
    case emptyPrompt
    case workerFailure(WorkerFailureCode)
    case missingPayload
    case invalidText
}

@MainActor
final class FormatterWorkerClient: TextFormatting {
    private let worker: WorkerRequestPerforming
    private let operationGate: ModelOperationGate
    private let loadTimeout: Duration
    private let formattingTimeout: Duration
    private var modelIDProvider: @MainActor () -> String?
    private var promptProvider: @MainActor () -> String
    private var loadedModelID: String?

    init(
        worker: WorkerRequestPerforming? = nil,
        operationGate: ModelOperationGate = ModelOperationGate(),
        loadTimeout: Duration = .seconds(120),
        formattingTimeout: Duration = .seconds(120),
        modelID: @escaping @MainActor () -> String? = { nil },
        prompt: @escaping @MainActor () -> String = { "" }
    ) {
        self.worker = worker ?? WorkerConnectionManager(
            makeTransport: {
                NSXPCWorkerTransport(
                    serviceName: WorkerEndpoint.formatter.serviceName
                )
            },
            logger: OSLogDiagnosticLogger(component: .app)
        )
        self.operationGate = operationGate
        self.loadTimeout = loadTimeout
        self.formattingTimeout = formattingTimeout
        modelIDProvider = modelID
        promptProvider = prompt
    }

    func configure(
        modelID: @escaping @MainActor () -> String?,
        prompt: @escaping @MainActor () -> String
    ) {
        modelIDProvider = modelID
        promptProvider = prompt
    }

    func format(
        _ text: String,
        requestID: PipelineRequestID
    ) async throws -> String {
        guard let modelID = modelIDProvider() else {
            throw FormatterWorkerClientError.modelUnavailable
        }
        let prompt = promptProvider()
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FormatterWorkerClientError.emptyPrompt
        }

        do {
            return try await operationGate.withOperation(for: modelID) {
                try await self.performFormatting(
                    text,
                    prompt: prompt,
                    modelID: modelID,
                    requestID: requestID
                )
            }
        } catch let error as WorkerConnectionError {
            loadedModelID = nil
            throw error
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

    private func performFormatting(
        _ text: String,
        prompt: String,
        modelID: String,
        requestID: PipelineRequestID
    ) async throws -> String {
        if loadedModelID != modelID {
            let loadReply = try await worker.perform(
                WorkerRequest(
                    requestID: PipelineRequestID(),
                    operation: .loadModel,
                    modelID: modelID
                ),
                timeout: loadTimeout
            )
            try validate(loadReply)
            loadedModelID = modelID
        }

        let reply = try await worker.perform(
            WorkerRequest(
                requestID: requestID,
                operation: .format,
                options: ["text": text, "prompt": prompt]
            ),
            timeout: formattingTimeout
        )
        try validate(reply)
        guard let payload = reply.payload else {
            throw FormatterWorkerClientError.missingPayload
        }
        guard let formattedText = String(data: payload, encoding: .utf8) else {
            throw FormatterWorkerClientError.invalidText
        }
        return formattedText
    }

    private func validate(_ reply: WorkerReply) throws {
        if let failure = reply.failure {
            throw FormatterWorkerClientError.workerFailure(failure.code)
        }
    }
}
