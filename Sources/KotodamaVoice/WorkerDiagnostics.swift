import Foundation
import KotodamaCore
import Observation

enum WorkerEndpoint: CaseIterable, Hashable {
    case speech
    case formatter

    var serviceName: String {
        switch self {
        case .speech:
            "jp.tsuyuki.KotodamaVoice.SpeechWorker"
        case .formatter:
            "jp.tsuyuki.KotodamaVoice.FormatterWorker"
        }
    }
}

enum WorkerDiagnosticState: Equatable {
    case disconnected
    case checking
    case connected(PipelineRequestID)
    case failed
}

@MainActor
final class WorkerDiagnosticClient {
    private lazy var managers: [WorkerEndpoint: WorkerConnectionManager] = [
        .speech: makeManager(for: .speech),
        .formatter: makeManager(for: .formatter),
    ]

    func echo(_ endpoint: WorkerEndpoint) async throws -> WorkerReply {
        guard let manager = managers[endpoint] else {
            throw WorkerDiagnosticError.invalidEndpoint
        }
        return try await manager.perform(
            WorkerRequest(
                requestID: PipelineRequestID(),
                operation: .diagnosticEcho
            ),
            timeout: .seconds(3)
        )
    }

    private func makeManager(
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

private enum WorkerDiagnosticError: Error {
    case invalidEndpoint
}

@MainActor
private final class NSXPCWorkerTransport: WorkerTransport {
    var interruptionHandler: (@MainActor @Sendable () -> Void)?
    var invalidationHandler: (@MainActor @Sendable () -> Void)?

    private let connection: NSXPCConnection

    init(serviceName: String) {
        connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(
            with: WorkerServiceProtocol.self
        )
    }

    func activate() {
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.interruptionHandler?()
            }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.invalidationHandler?()
            }
        }
        connection.activate()
    }

    func send(
        _ request: WorkerRequest,
        reply: @escaping @MainActor @Sendable (WorkerReply) -> Void
    ) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in
                self?.connection.invalidate()
            }
        }
        guard let service = proxy as? WorkerServiceProtocol else {
            connection.invalidate()
            return
        }
        service.perform(request) { replyValue in
            Task { @MainActor in
                reply(replyValue)
            }
        }
    }

    func cancel(requestID: PipelineRequestID) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in }
        guard let service = proxy as? WorkerServiceProtocol else { return }
        service.perform(
            WorkerRequest(requestID: requestID, operation: .cancel)
        ) { _ in }
    }

    func invalidate() {
        connection.invalidate()
    }
}

@Observable
@MainActor
final class WorkerDiagnostics {
    private(set) var states: [WorkerEndpoint: WorkerDiagnosticState] = [
        .speech: .disconnected,
        .formatter: .disconnected,
    ]

    private let client: WorkerDiagnosticClient

    init(client: WorkerDiagnosticClient = WorkerDiagnosticClient()) {
        self.client = client
    }

    func checkAll() {
        for endpoint in WorkerEndpoint.allCases {
            states[endpoint] = .checking
            Task {
                do {
                    let reply = try await client.echo(endpoint)
                    guard reply.failure == nil else {
                        states[endpoint] = .failed
                        return
                    }
                    states[endpoint] = .connected(reply.requestID)
                } catch {
                    states[endpoint] = .failed
                }
            }
        }
    }
}
