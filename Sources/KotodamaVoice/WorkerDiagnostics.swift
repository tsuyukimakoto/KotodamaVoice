import Foundation
import KotodamaCore
import Observation

enum WorkerEndpoint: CaseIterable, Hashable {
    case speech
    case formatter

    var serviceName: String {
        switch self {
        case .speech:
            "jp.tsuyuki.KotodamaVoice.worker.speech"
        case .formatter:
            "jp.tsuyuki.KotodamaVoice.worker.formatter"
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

    func echo(
        _ endpoint: WorkerEndpoint,
        requestID: PipelineRequestID = PipelineRequestID()
    ) async throws -> WorkerReply {
        guard let manager = managers[endpoint] else {
            throw WorkerDiagnosticError.invalidEndpoint
        }
        return try await manager.perform(
            WorkerRequest(
                requestID: requestID,
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
final class NSXPCWorkerTransport: WorkerTransport {
    var interruptionHandler: (@MainActor @Sendable () -> Void)?
    var invalidationHandler: (@MainActor @Sendable () -> Void)?

    private let connectionHandle: XPCConnectionHandle

    private var connection: NSXPCConnection {
        connectionHandle.connection
    }

    init(serviceName: String) {
        let connection = NSXPCConnection(serviceName: serviceName)
        connectionHandle = XPCConnectionHandle(connection: connection)
        connection.remoteObjectInterface = NSXPCInterface(
            with: WorkerServiceProtocol.self
        )
    }

    func activate() {
        let interruptionHandler = self.interruptionHandler
        let invalidationHandler = self.invalidationHandler
        connection.interruptionHandler = { @Sendable in
            Task { @MainActor in
                interruptionHandler?()
            }
        }
        connection.invalidationHandler = { @Sendable in
            Task { @MainActor in
                invalidationHandler?()
            }
        }
        connection.activate()
    }

    func send(
        _ request: WorkerRequest,
        reply: @escaping @MainActor @Sendable (WorkerReply) -> Void
    ) {
        let connectionHandle = self.connectionHandle
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
            connectionHandle.connection.invalidate()
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

private final class XPCConnectionHandle: @unchecked Sendable {
    let connection: NSXPCConnection

    init(connection: NSXPCConnection) {
        self.connection = connection
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
