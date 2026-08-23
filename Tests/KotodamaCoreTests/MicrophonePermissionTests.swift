import Testing
@testable import KotodamaCore

@Test @MainActor
func microphonePermissionIsNotRequestedDuringInitialization() {
    let permission = MicrophonePermissionSpy(status: .notDetermined)
    let store = PipelineStore()
    _ = RecordingStartCoordinator(
        pipeline: PipelineCoordinator(store: store),
        store: store,
        permission: permission
    )

    #expect(permission.requestCount == 0)
    #expect(store.state == .ready)
}

@Test @MainActor
func firstRecordingRequestsUndeterminedPermission() async throws {
    let permission = MicrophonePermissionSpy(status: .notDetermined)
    permission.requestResult = true
    let store = PipelineStore()
    let coordinator = RecordingStartCoordinator(
        pipeline: PipelineCoordinator(store: store),
        store: store,
        permission: permission
    )

    _ = try await coordinator.beginRecording()

    #expect(permission.requestCount == 1)
    #expect(store.state == .recording)
}

@Test @MainActor
func deniedMicrophonePermissionLeavesPipelineReady() async {
    let permission = MicrophonePermissionSpy(status: .denied)
    let store = PipelineStore()
    let coordinator = RecordingStartCoordinator(
        pipeline: PipelineCoordinator(store: store),
        store: store,
        permission: permission
    )

    await #expect(throws: RecordingStartError.microphonePermissionDenied) {
        try await coordinator.beginRecording()
    }
    #expect(permission.requestCount == 0)
    #expect(store.state == .ready)
}

@MainActor
private final class MicrophonePermissionSpy: MicrophonePermissionRequesting {
    var status: MicrophoneAuthorizationStatus
    var requestResult = false
    private(set) var requestCount = 0

    init(status: MicrophoneAuthorizationStatus) {
        self.status = status
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        status = requestResult ? .authorized : .denied
        return requestResult
    }
}
