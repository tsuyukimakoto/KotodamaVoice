import Foundation

public struct PipelineRequestID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum PipelineState: Equatable, Sendable {
    case ready
    case recording
    case transcribing(PipelineRequestID)
    case formatting(PipelineRequestID)
    case outputting(PipelineRequestID)
    case cancelling(PipelineRequestID?)
    case failed(PipelineRequestID?)
}

public enum PipelineCommand: Equatable, Sendable {
    case beginRecording
    case stopRecording(requestID: PipelineRequestID)
    case transcriptionCompleted(
        requestID: PipelineRequestID,
        requiresFormatting: Bool
    )
    case formattingCompleted(requestID: PipelineRequestID)
    case outputCompleted(requestID: PipelineRequestID)
    case cancel
    case cancellationCompleted(requestID: PipelineRequestID?)
    case fail(requestID: PipelineRequestID?)
    case recover
}

public enum PipelineTransitionResult: Equatable, Sendable {
    case applied
    case ignoredBusy
}

public enum PipelineTransitionError: Error, Equatable, Sendable {
    case invalidTransition
    case requestMismatch
}

public struct PipelineStateMachine: Sendable {
    public private(set) var state: PipelineState

    public init(state: PipelineState = .ready) {
        self.state = state
    }

    @discardableResult
    public mutating func apply(
        _ command: PipelineCommand
    ) throws -> PipelineTransitionResult {
        switch command {
        case .beginRecording:
            switch state {
            case .ready:
                state = .recording
                return .applied
            case .transcribing, .formatting, .outputting, .cancelling:
                return .ignoredBusy
            case .recording, .failed:
                throw PipelineTransitionError.invalidTransition
            }

        case let .stopRecording(requestID):
            guard state == .recording else {
                throw PipelineTransitionError.invalidTransition
            }
            state = .transcribing(requestID)

        case let .transcriptionCompleted(requestID, requiresFormatting):
            try requireActiveRequest(requestID, phase: .transcribing)
            state = requiresFormatting
                ? .formatting(requestID)
                : .outputting(requestID)

        case let .formattingCompleted(requestID):
            try requireActiveRequest(requestID, phase: .formatting)
            state = .outputting(requestID)

        case let .outputCompleted(requestID):
            try requireActiveRequest(requestID, phase: .outputting)
            state = .ready

        case .cancel:
            switch state {
            case .recording:
                state = .cancelling(nil)
            case let .transcribing(requestID),
                 let .formatting(requestID),
                 let .outputting(requestID):
                state = .cancelling(requestID)
            case .ready, .cancelling, .failed:
                throw PipelineTransitionError.invalidTransition
            }

        case let .cancellationCompleted(requestID):
            guard case let .cancelling(activeRequestID) = state else {
                throw PipelineTransitionError.invalidTransition
            }
            guard activeRequestID == requestID else {
                throw PipelineTransitionError.requestMismatch
            }
            state = .ready

        case let .fail(requestID):
            try validateFailureRequest(requestID)
            state = .failed(requestID)

        case .recover:
            guard case .failed = state else {
                throw PipelineTransitionError.invalidTransition
            }
            state = .ready
        }

        return .applied
    }

    private enum RequestPhase {
        case transcribing
        case formatting
        case outputting
    }

    private func requireActiveRequest(
        _ requestID: PipelineRequestID,
        phase: RequestPhase
    ) throws {
        let activeRequestID: PipelineRequestID
        switch (phase, state) {
        case let (.transcribing, .transcribing(value)),
             let (.formatting, .formatting(value)),
             let (.outputting, .outputting(value)):
            activeRequestID = value
        default:
            throw PipelineTransitionError.invalidTransition
        }

        guard activeRequestID == requestID else {
            throw PipelineTransitionError.requestMismatch
        }
    }

    private func validateFailureRequest(
        _ requestID: PipelineRequestID?
    ) throws {
        switch state {
        case .ready, .failed:
            throw PipelineTransitionError.invalidTransition
        case .recording:
            guard requestID == nil else {
                throw PipelineTransitionError.requestMismatch
            }
        case let .transcribing(activeRequestID),
             let .formatting(activeRequestID),
             let .outputting(activeRequestID):
            guard requestID == activeRequestID else {
                throw PipelineTransitionError.requestMismatch
            }
        case let .cancelling(activeRequestID):
            guard requestID == activeRequestID else {
                throw PipelineTransitionError.requestMismatch
            }
        }
    }
}
