import Foundation
import OSLog

public enum DiagnosticComponent: String, Sendable {
    case app
    case speechWorker
    case formatterWorker
}

public enum DiagnosticStage: String, Sendable {
    case requested
    case accepted
    case completed
    case failed
    case interrupted
    case invalidated
    case timedOut
    case cancelled
}

public struct DiagnosticRecord: Equatable, Sendable {
    public let component: DiagnosticComponent
    public let requestID: PipelineRequestID
    public let operation: WorkerOperation
    public let stage: DiagnosticStage
    public let failureCode: WorkerFailureCode?

    public init(
        component: DiagnosticComponent,
        requestID: PipelineRequestID,
        operation: WorkerOperation,
        stage: DiagnosticStage,
        failureCode: WorkerFailureCode? = nil
    ) {
        self.component = component
        self.requestID = requestID
        self.operation = operation
        self.stage = stage
        self.failureCode = failureCode
    }

    public var osLogMessage: String {
        "request_id=\(requestID.rawValue.uuidString) "
            + "operation=\(operation) "
            + "stage=\(stage.rawValue) "
            + "failure=\(String(describing: failureCode))"
    }
}

public protocol DiagnosticLogging: Sendable {
    func record(_ record: DiagnosticRecord)
}

public struct OSLogDiagnosticLogger: DiagnosticLogging {
    private let logger: Logger

    public init(component: DiagnosticComponent) {
        logger = Logger(
            subsystem: "jp.tsuyuki.KotodamaVoice",
            category: component.rawValue
        )
    }

    public func record(_ record: DiagnosticRecord) {
        logger.info("\(record.osLogMessage, privacy: .public)")
    }
}

public struct NoopDiagnosticLogger: DiagnosticLogging {
    public init() {}
    public func record(_ record: DiagnosticRecord) {}
}
