import Foundation

public enum MicrophoneAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

@MainActor
public protocol MicrophonePermissionRequesting: AnyObject {
    var status: MicrophoneAuthorizationStatus { get }
    func requestAccess() async -> Bool
}

public enum RecordingStartError: Error, Equatable, Sendable {
    case microphonePermissionDenied
}

@MainActor
public final class RecordingStartCoordinator {
    private let pipeline: PipelineCoordinator
    private let store: PipelineStore
    private let permission: MicrophonePermissionRequesting
    private var isRequestingPermission = false

    public init(
        pipeline: PipelineCoordinator,
        store: PipelineStore,
        permission: MicrophonePermissionRequesting
    ) {
        self.pipeline = pipeline
        self.store = store
        self.permission = permission
    }

    public func beginRecording() async throws -> PipelineTransitionResult {
        guard !isRequestingPermission else {
            return .ignoredBusy
        }
        switch store.state {
        case .transcribing, .formatting, .outputting, .cancelling:
            return .ignoredBusy
        case .ready, .recording, .failed:
            break
        }

        let isAuthorized: Bool
        switch permission.status {
        case .authorized:
            isAuthorized = true
        case .denied, .restricted:
            isAuthorized = false
        case .notDetermined:
            isRequestingPermission = true
            isAuthorized = await permission.requestAccess()
            isRequestingPermission = false
        }

        guard isAuthorized else {
            throw RecordingStartError.microphonePermissionDenied
        }
        return try pipeline.beginRecording()
    }
}
