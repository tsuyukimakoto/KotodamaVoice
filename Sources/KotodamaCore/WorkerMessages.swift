import Foundation

public enum WorkerOperation: Int, Sendable {
    case diagnosticEcho
    case loadModel
    case unloadModel
    case state
    case shutdown
    case cancel
    case transcribe
    case format
}

public enum WorkerPhase: Int, Sendable {
    case accepted
    case loading
    case processing
    case unloading
    case finished
}

public enum WorkerFailureCode: Int, Sendable {
    case protocolMismatch
    case invalidRequest
    case modelNotInstalled
    case modelLoadFailed
    case processingFailed
    case cancelled
    case timedOut
    case workerUnavailable
}

public enum WorkerLifecycleState: String, Codable, Sendable {
    case idle
    case loaded
    case shutDown
}

public struct WorkerSnapshot: Codable, Equatable, Sendable {
    public let state: WorkerLifecycleState
    public let modelID: String?

    public init(state: WorkerLifecycleState, modelID: String?) {
        self.state = state
        self.modelID = modelID
    }
}

public struct WorkerProcessSnapshot: Codable, Equatable, Sendable {
    public let processIdentifier: Int32

    public init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }
}

public protocol WorkerRuntimeManaging: AnyObject {
    func load(modelID: String) throws
    func cancel(requestID: PipelineRequestID)
    func cancelAll()
    func unload()
}

public enum WorkerRuntimeError: Error, Equatable, Sendable {
    case invalidInput
    case cancelled
    case processingFailed
}

public protocol SpeechTranscribingRuntime: WorkerRuntimeManaging {
    func transcribe(
        audioInput: WorkerAudioInput,
        requestID: PipelineRequestID
    ) throws -> String
}

@objc(KVWorkerAudioInput)
public final class WorkerAudioInput: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let fileHandle: FileHandle
    public let sampleRate: Double
    public let channelCount: Int
    public let sampleCount: Int64

    public init(
        fileHandle: FileHandle,
        sampleRate: Double,
        channelCount: Int,
        sampleCount: Int64
    ) {
        self.fileHandle = fileHandle
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sampleCount = sampleCount
    }

    public required init?(coder: NSCoder) {
        guard let fileHandle = coder.decodeObject(
            of: FileHandle.self,
            forKey: Key.fileHandle
        ) else {
            return nil
        }
        self.fileHandle = fileHandle
        sampleRate = coder.decodeDouble(forKey: Key.sampleRate)
        channelCount = coder.decodeInteger(forKey: Key.channelCount)
        sampleCount = coder.decodeInt64(forKey: Key.sampleCount)
    }

    public func encode(with coder: NSCoder) {
        coder.encode(fileHandle, forKey: Key.fileHandle)
        coder.encode(sampleRate, forKey: Key.sampleRate)
        coder.encode(channelCount, forKey: Key.channelCount)
        coder.encode(sampleCount, forKey: Key.sampleCount)
    }

    private enum Key {
        static let fileHandle = "fileHandle"
        static let sampleRate = "sampleRate"
        static let channelCount = "channelCount"
        static let sampleCount = "sampleCount"
    }
}

@objc(KVWorkerRequest)
public final class WorkerRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let protocolVersion: Int
    public let requestID: PipelineRequestID
    public let operation: WorkerOperation
    public let modelID: String?
    public let options: [String: String]
    public let audioInput: WorkerAudioInput?

    public init(
        protocolVersion: Int = KotodamaCore.protocolVersion,
        requestID: PipelineRequestID,
        operation: WorkerOperation,
        modelID: String? = nil,
        options: [String: String] = [:],
        audioInput: WorkerAudioInput? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.modelID = modelID
        self.options = options
        self.audioInput = audioInput
    }

    public required init?(coder: NSCoder) {
        guard let requestUUID = coder.decodeObject(
            of: NSUUID.self,
            forKey: Key.requestID
        ),
            let operation = WorkerOperation(
                rawValue: coder.decodeInteger(forKey: Key.operation)
            ),
            let options = coder.decodeObject(
                of: [NSDictionary.self, NSString.self],
                forKey: Key.options
            ) as? [String: String]
        else {
            return nil
        }

        protocolVersion = coder.decodeInteger(forKey: Key.protocolVersion)
        requestID = PipelineRequestID(rawValue: requestUUID as UUID)
        self.operation = operation
        modelID = coder.decodeObject(of: NSString.self, forKey: Key.modelID) as String?
        self.options = options
        audioInput = coder.decodeObject(
            of: WorkerAudioInput.self,
            forKey: Key.audioInput
        )
    }

    public func encode(with coder: NSCoder) {
        coder.encode(protocolVersion, forKey: Key.protocolVersion)
        coder.encode(requestID.rawValue as NSUUID, forKey: Key.requestID)
        coder.encode(operation.rawValue, forKey: Key.operation)
        coder.encode(modelID as NSString?, forKey: Key.modelID)
        coder.encode(options as NSDictionary, forKey: Key.options)
        coder.encode(audioInput, forKey: Key.audioInput)
    }

    public override var description: String {
        "<WorkerRequest requestID=\(requestID.rawValue) operation=\(operation)>"
    }

    private enum Key {
        static let protocolVersion = "protocolVersion"
        static let requestID = "requestID"
        static let operation = "operation"
        static let modelID = "modelID"
        static let options = "options"
        static let audioInput = "audioInput"
    }
}

@objc(KVWorkerEvent)
public final class WorkerEvent: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let requestID: PipelineRequestID
    public let phase: WorkerPhase
    public let progress: Double
    public let metrics: [String: Double]

    public init(
        requestID: PipelineRequestID,
        phase: WorkerPhase,
        progress: Double,
        metrics: [String: Double] = [:]
    ) {
        self.requestID = requestID
        self.phase = phase
        self.progress = progress
        self.metrics = metrics
    }

    public required init?(coder: NSCoder) {
        guard let requestUUID = coder.decodeObject(
            of: NSUUID.self,
            forKey: Key.requestID
        ),
            let phase = WorkerPhase(
                rawValue: coder.decodeInteger(forKey: Key.phase)
            ),
            let metrics = coder.decodeObject(
                of: [NSDictionary.self, NSString.self, NSNumber.self],
                forKey: Key.metrics
            ) as? [String: Double]
        else {
            return nil
        }

        requestID = PipelineRequestID(rawValue: requestUUID as UUID)
        self.phase = phase
        progress = coder.decodeDouble(forKey: Key.progress)
        self.metrics = metrics
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID.rawValue as NSUUID, forKey: Key.requestID)
        coder.encode(phase.rawValue, forKey: Key.phase)
        coder.encode(progress, forKey: Key.progress)
        coder.encode(metrics as NSDictionary, forKey: Key.metrics)
    }

    public override var description: String {
        "<WorkerEvent requestID=\(requestID.rawValue) phase=\(phase) progress=\(progress)>"
    }

    private enum Key {
        static let requestID = "requestID"
        static let phase = "phase"
        static let progress = "progress"
        static let metrics = "metrics"
    }
}

@objc(KVWorkerFailure)
public final class WorkerFailure: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let code: WorkerFailureCode
    public let isRetryable: Bool
    public let underlyingCode: Int

    public init(
        code: WorkerFailureCode,
        isRetryable: Bool,
        underlyingCode: Int = 0
    ) {
        self.code = code
        self.isRetryable = isRetryable
        self.underlyingCode = underlyingCode
    }

    public required init?(coder: NSCoder) {
        guard let code = WorkerFailureCode(
            rawValue: coder.decodeInteger(forKey: Key.code)
        ) else {
            return nil
        }
        self.code = code
        isRetryable = coder.decodeBool(forKey: Key.isRetryable)
        underlyingCode = coder.decodeInteger(forKey: Key.underlyingCode)
    }

    public func encode(with coder: NSCoder) {
        coder.encode(code.rawValue, forKey: Key.code)
        coder.encode(isRetryable, forKey: Key.isRetryable)
        coder.encode(underlyingCode, forKey: Key.underlyingCode)
    }

    public override var description: String {
        "<WorkerFailure code=\(code) retryable=\(isRetryable) underlyingCode=\(underlyingCode)>"
    }

    private enum Key {
        static let code = "code"
        static let isRetryable = "isRetryable"
        static let underlyingCode = "underlyingCode"
    }
}

@objc(KVWorkerReply)
public final class WorkerReply: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let protocolVersion: Int
    public let requestID: PipelineRequestID
    public let payload: Data?
    public let failure: WorkerFailure?

    public init(
        protocolVersion: Int = KotodamaCore.protocolVersion,
        requestID: PipelineRequestID,
        payload: Data? = nil,
        failure: WorkerFailure? = nil
    ) {
        precondition(payload == nil || failure == nil)
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.payload = payload
        self.failure = failure
    }

    public convenience init(
        requestID: PipelineRequestID,
        failure: WorkerFailure
    ) {
        self.init(requestID: requestID, payload: nil, failure: failure)
    }

    public required init?(coder: NSCoder) {
        guard let requestUUID = coder.decodeObject(
            of: NSUUID.self,
            forKey: Key.requestID
        ) else {
            return nil
        }
        let payload = coder.decodeObject(of: NSData.self, forKey: Key.payload) as Data?
        let failure = coder.decodeObject(
            of: WorkerFailure.self,
            forKey: Key.failure
        )
        guard payload == nil || failure == nil else {
            return nil
        }

        protocolVersion = coder.decodeInteger(forKey: Key.protocolVersion)
        requestID = PipelineRequestID(rawValue: requestUUID as UUID)
        self.payload = payload
        self.failure = failure
    }

    public func encode(with coder: NSCoder) {
        coder.encode(protocolVersion, forKey: Key.protocolVersion)
        coder.encode(requestID.rawValue as NSUUID, forKey: Key.requestID)
        coder.encode(payload as NSData?, forKey: Key.payload)
        coder.encode(failure, forKey: Key.failure)
    }

    public override var description: String {
        let outcome = failure == nil ? "success" : "failure"
        return "<WorkerReply requestID=\(requestID.rawValue) outcome=\(outcome)>"
    }

    private enum Key {
        static let protocolVersion = "protocolVersion"
        static let requestID = "requestID"
        static let payload = "payload"
        static let failure = "failure"
    }
}

@objc public protocol WorkerServiceProtocol {
    func perform(
        _ request: WorkerRequest,
        withReply reply: @escaping (WorkerReply) -> Void
    )
}

public final class WorkerService: NSObject, WorkerServiceProtocol {
    private let runtime: WorkerRuntimeManaging
    private let logger: DiagnosticLogging
    private let component: DiagnosticComponent
    private let lock = NSLock()
    private var lifecycleState: WorkerLifecycleState = .idle
    private var modelID: String?

    public override convenience init() {
        self.init(
            runtime: NoopWorkerRuntime(),
            logger: NoopDiagnosticLogger(),
            component: .app
        )
    }

    public convenience init(runtime: WorkerRuntimeManaging) {
        self.init(
            runtime: runtime,
            logger: NoopDiagnosticLogger(),
            component: .app
        )
    }

    public init(
        runtime: WorkerRuntimeManaging,
        logger: DiagnosticLogging,
        component: DiagnosticComponent
    ) {
        self.runtime = runtime
        self.logger = logger
        self.component = component
        super.init()
    }

    public func perform(
        _ request: WorkerRequest,
        withReply reply: @escaping (WorkerReply) -> Void
    ) {
        logger.record(
            DiagnosticRecord(
                component: component,
                requestID: request.requestID,
                operation: request.operation,
                stage: .accepted
            )
        )
        let replyValue = handle(request)
        logger.record(
            DiagnosticRecord(
                component: component,
                requestID: request.requestID,
                operation: request.operation,
                stage: replyValue.failure == nil ? .completed : .failed,
                failureCode: replyValue.failure?.code
            )
        )
        reply(replyValue)
    }

    private func handle(_ request: WorkerRequest) -> WorkerReply {
        guard request.protocolVersion == KotodamaCore.protocolVersion else {
            return WorkerReply(
                requestID: request.requestID,
                failure: WorkerFailure(
                    code: .protocolMismatch,
                    isRetryable: false
                )
            )
        }

        switch request.operation {
        case .cancel:
            runtime.cancel(requestID: request.requestID)
            return WorkerReply(requestID: request.requestID)

        case .transcribe:
            lock.lock()
            let speechRuntime = runtime as? SpeechTranscribingRuntime
            let canTranscribe = lifecycleState == .loaded
            lock.unlock()
            guard canTranscribe,
                  let speechRuntime,
                  let audioInput = request.audioInput
            else {
                return invalidRequestReply(for: request.requestID)
            }
            return transcribe(
                audioInput: audioInput,
                requestID: request.requestID,
                runtime: speechRuntime
            )

        default:
            lock.lock()
            defer { lock.unlock() }
            return handleSerialized(request)
        }
    }

    private func handleSerialized(_ request: WorkerRequest) -> WorkerReply {
        switch request.operation {
        case .diagnosticEcho:
            let snapshot = WorkerProcessSnapshot(
                processIdentifier: ProcessInfo.processInfo.processIdentifier
            )
            guard let payload = try? JSONEncoder().encode(snapshot) else {
                return invalidRequestReply(for: request.requestID)
            }
            return WorkerReply(
                requestID: request.requestID,
                payload: payload
            )

        case .loadModel:
            guard lifecycleState != .shutDown,
                  let modelID = request.modelID,
                  !modelID.isEmpty
            else {
                return invalidRequestReply(for: request.requestID)
            }
            do {
                runtime.cancelAll()
                runtime.unload()
                try runtime.load(modelID: modelID)
                self.modelID = modelID
                lifecycleState = .loaded
                return WorkerReply(requestID: request.requestID)
            } catch {
                self.modelID = nil
                lifecycleState = .idle
                return WorkerReply(
                    requestID: request.requestID,
                    failure: WorkerFailure(
                        code: .modelLoadFailed,
                        isRetryable: true,
                        underlyingCode: (error as NSError).code
                    )
                )
            }

        case .unloadModel:
            guard lifecycleState != .shutDown else {
                return invalidRequestReply(for: request.requestID)
            }
            runtime.cancelAll()
            runtime.unload()
            modelID = nil
            lifecycleState = .idle
            return WorkerReply(requestID: request.requestID)

        case .state:
            let snapshot = WorkerSnapshot(
                state: lifecycleState,
                modelID: modelID
            )
            guard let payload = try? JSONEncoder().encode(snapshot) else {
                return invalidRequestReply(for: request.requestID)
            }
            return WorkerReply(
                requestID: request.requestID,
                payload: payload
            )

        case .shutdown:
            runtime.cancelAll()
            runtime.unload()
            modelID = nil
            lifecycleState = .shutDown
            return WorkerReply(requestID: request.requestID)

        case .cancel, .transcribe, .format:
            return invalidRequestReply(for: request.requestID)
        }
    }

    private func transcribe(
        audioInput: WorkerAudioInput,
        requestID: PipelineRequestID,
        runtime: SpeechTranscribingRuntime
    ) -> WorkerReply {
        do {
            let text = try runtime.transcribe(
                audioInput: audioInput,
                requestID: requestID
            )
            return WorkerReply(
                requestID: requestID,
                payload: Data(text.utf8)
            )
        } catch WorkerRuntimeError.cancelled {
            return WorkerReply(
                requestID: requestID,
                failure: WorkerFailure(code: .cancelled, isRetryable: true)
            )
        } catch WorkerRuntimeError.invalidInput {
            return WorkerReply(
                requestID: requestID,
                failure: WorkerFailure(code: .invalidRequest, isRetryable: false)
            )
        } catch {
            return WorkerReply(
                requestID: requestID,
                failure: WorkerFailure(
                    code: .processingFailed,
                    isRetryable: true,
                    underlyingCode: (error as NSError).code
                )
            )
        }
    }

    private func invalidRequestReply(
        for requestID: PipelineRequestID
    ) -> WorkerReply {
        WorkerReply(
            requestID: requestID,
            failure: WorkerFailure(
                code: .invalidRequest,
                isRetryable: false
            )
        )
    }
}

private final class NoopWorkerRuntime: WorkerRuntimeManaging {
    func load(modelID: String) throws {}
    func cancel(requestID: PipelineRequestID) {}
    func cancelAll() {}
    func unload() {}
}
