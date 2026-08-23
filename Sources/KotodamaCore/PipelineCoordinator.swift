import Observation

@Observable
@MainActor
public final class PipelineStore {
    public private(set) var state: PipelineState

    @ObservationIgnored
    private var stateMachine: PipelineStateMachine

    public init(initialState: PipelineState = .ready) {
        state = initialState
        stateMachine = PipelineStateMachine(state: initialState)
    }

    @discardableResult
    fileprivate func apply(
        _ command: PipelineCommand
    ) throws -> PipelineTransitionResult {
        let result = try stateMachine.apply(command)
        state = stateMachine.state
        return result
    }
}

@MainActor
public final class PipelineCoordinator {
    public let store: PipelineStore

    private let makeRequestID: () -> PipelineRequestID

    public init(
        store: PipelineStore,
        makeRequestID: @escaping () -> PipelineRequestID = {
            PipelineRequestID()
        }
    ) {
        self.store = store
        self.makeRequestID = makeRequestID
    }

    @discardableResult
    public func beginRecording() throws -> PipelineTransitionResult {
        try store.apply(.beginRecording)
    }

    @discardableResult
    public func stopRecording() throws -> PipelineRequestID {
        let requestID = makeRequestID()
        try store.apply(.stopRecording(requestID: requestID))
        return requestID
    }

    @discardableResult
    public func completeTranscription(
        requestID: PipelineRequestID,
        requiresFormatting: Bool
    ) throws -> PipelineTransitionResult {
        try store.apply(
            .transcriptionCompleted(
                requestID: requestID,
                requiresFormatting: requiresFormatting
            )
        )
    }

    @discardableResult
    public func completeFormatting(
        requestID: PipelineRequestID
    ) throws -> PipelineTransitionResult {
        try store.apply(.formattingCompleted(requestID: requestID))
    }

    @discardableResult
    public func completeOutput(
        requestID: PipelineRequestID
    ) throws -> PipelineTransitionResult {
        try store.apply(.outputCompleted(requestID: requestID))
    }

    @discardableResult
    public func cancel() throws -> PipelineTransitionResult {
        try store.apply(.cancel)
    }

    @discardableResult
    public func completeCancellation(
        requestID: PipelineRequestID?
    ) throws -> PipelineTransitionResult {
        try store.apply(.cancellationCompleted(requestID: requestID))
    }

    @discardableResult
    public func fail(
        requestID: PipelineRequestID?
    ) throws -> PipelineTransitionResult {
        try store.apply(.fail(requestID: requestID))
    }

    @discardableResult
    public func recover() throws -> PipelineTransitionResult {
        try store.apply(.recover)
    }
}
