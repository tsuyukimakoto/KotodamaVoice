import Foundation
import KotodamaCore

@MainActor
protocol ModelWorkerUnloading: AnyObject {
    func unload(_ model: ModelManifestEntry) async throws
}

enum ModelWorkerUnloadError: Error, Equatable {
    case workerFailure(WorkerFailureCode)
}

@MainActor
final class XPCModelWorkerUnloader: ModelWorkerUnloading {
    private let speechClient: SpeechWorkerClient
    private let formatterWorker: WorkerRequestPerforming

    init(
        speechClient: SpeechWorkerClient? = nil,
        formatterWorker: WorkerRequestPerforming? = nil
    ) {
        self.speechClient = speechClient ?? SpeechWorkerClient()
        self.formatterWorker = formatterWorker ?? Self.makeWorker(for: .formatter)
    }

    func unload(_ model: ModelManifestEntry) async throws {
        switch model.purpose {
        case .speech:
            do {
                try await speechClient.unload(modelID: model.id)
            } catch let SpeechWorkerClientError.workerFailure(code) {
                throw ModelWorkerUnloadError.workerFailure(code)
            }
        case .formatter:
            let reply = try await formatterWorker.perform(
                WorkerRequest(
                    requestID: PipelineRequestID(),
                    operation: .unloadModel,
                    modelID: model.id
                ),
                timeout: .seconds(30)
            )
            if let failure = reply.failure {
                throw ModelWorkerUnloadError.workerFailure(failure.code)
            }
        }
    }

    private static func makeWorker(
        for endpoint: WorkerEndpoint
    ) -> WorkerConnectionManager {
        WorkerConnectionManager(
            makeTransport: {
                NSXPCWorkerTransport(serviceName: endpoint.serviceName)
            },
            logger: OSLogDiagnosticLogger(component: .app)
        )
    }
}
