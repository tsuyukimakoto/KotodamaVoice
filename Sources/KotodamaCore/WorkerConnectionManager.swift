import Foundation

public enum WorkerConnectionError: Error, Equatable, Sendable {
    case timedOut
    case interrupted
    case invalidated
    case duplicateRequest
    case protocolMismatch
    case requestMismatch
}

@MainActor
public protocol WorkerTransport: AnyObject {
    var interruptionHandler: (@MainActor () -> Void)? { get set }
    var invalidationHandler: (@MainActor () -> Void)? { get set }

    func activate()
    func send(
        _ request: WorkerRequest,
        reply: @escaping @MainActor (WorkerReply) -> Void
    )
    func cancel(requestID: PipelineRequestID)
    func invalidate()
}

@MainActor
public final class WorkerConnectionManager {
    private struct PendingRequest {
        let operation: WorkerOperation
        let continuation: CheckedContinuation<WorkerReply, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let makeTransport: @MainActor () -> WorkerTransport
    private let logger: DiagnosticLogging
    private var transport: WorkerTransport?
    private var transportGeneration: UUID?
    private var pending: [PipelineRequestID: PendingRequest] = [:]

    public init(
        makeTransport: @escaping @MainActor () -> WorkerTransport,
        logger: DiagnosticLogging = NoopDiagnosticLogger()
    ) {
        self.makeTransport = makeTransport
        self.logger = logger
    }

    public func perform(
        _ request: WorkerRequest,
        timeout: Duration
    ) async throws -> WorkerReply {
        try Task.checkCancellation()
        let requestID = request.requestID
        logger.record(
            DiagnosticRecord(
                component: .app,
                requestID: requestID,
                operation: request.operation,
                stage: .requested
            )
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending[requestID] == nil else {
                    continuation.resume(
                        throwing: WorkerConnectionError.duplicateRequest
                    )
                    return
                }

                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.complete(
                        requestID,
                        with: .failure(WorkerConnectionError.timedOut)
                    )
                }
                pending[requestID] = PendingRequest(
                    operation: request.operation,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )

                currentTransport().send(request) { [weak self] reply in
                    self?.receive(reply, for: requestID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID)
            }
        }
    }

    public func invalidate() {
        failAll(with: .invalidated)
        transport?.invalidate()
        transport = nil
        transportGeneration = nil
    }

    private func currentTransport() -> WorkerTransport {
        if let transport {
            return transport
        }

        let transport = makeTransport()
        let generation = UUID()
        transport.interruptionHandler = { [weak self] in
            self?.handleInterruption(generation: generation)
        }
        transport.invalidationHandler = { [weak self] in
            self?.handleInvalidation(generation: generation)
        }
        self.transport = transport
        transportGeneration = generation
        transport.activate()
        return transport
    }

    private func receive(
        _ reply: WorkerReply,
        for requestID: PipelineRequestID
    ) {
        guard pending[requestID] != nil else { return }
        guard reply.protocolVersion == KotodamaCore.protocolVersion else {
            complete(
                requestID,
                with: .failure(WorkerConnectionError.protocolMismatch)
            )
            return
        }
        guard reply.requestID == requestID else {
            complete(
                requestID,
                with: .failure(WorkerConnectionError.requestMismatch)
            )
            return
        }
        complete(requestID, with: .success(reply))
    }

    private func cancel(_ requestID: PipelineRequestID) {
        guard pending[requestID] != nil else { return }
        transport?.cancel(requestID: requestID)
        complete(requestID, with: .failure(CancellationError()))
    }

    private func handleInterruption(generation: UUID) {
        guard transportGeneration == generation else { return }
        failAll(with: .interrupted)
    }

    private func handleInvalidation(generation: UUID) {
        guard transportGeneration == generation else { return }
        failAll(with: .invalidated)
        transport = nil
        transportGeneration = nil
    }

    private func failAll(with error: WorkerConnectionError) {
        for requestID in Array(pending.keys) {
            complete(requestID, with: .failure(error))
        }
    }

    private func complete(
        _ requestID: PipelineRequestID,
        with result: Result<WorkerReply, Error>
    ) {
        guard let request = pending.removeValue(forKey: requestID) else {
            return
        }
        request.timeoutTask.cancel()
        let stage: DiagnosticStage
        let failureCode: WorkerFailureCode?
        switch result {
        case let .success(reply):
            stage = reply.failure == nil ? .completed : .failed
            failureCode = reply.failure?.code
        case let .failure(error):
            failureCode = nil
            switch error {
            case WorkerConnectionError.interrupted:
                stage = .interrupted
            case WorkerConnectionError.invalidated:
                stage = .invalidated
            case WorkerConnectionError.timedOut:
                stage = .timedOut
            case is CancellationError:
                stage = .cancelled
            default:
                stage = .failed
            }
        }
        logger.record(
            DiagnosticRecord(
                component: .app,
                requestID: requestID,
                operation: request.operation,
                stage: stage,
                failureCode: failureCode
            )
        )
        request.continuation.resume(with: result)
    }
}
