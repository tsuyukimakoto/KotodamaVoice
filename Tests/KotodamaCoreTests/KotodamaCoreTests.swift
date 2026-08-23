import Foundation
import Testing
@testable import KotodamaCore

@Test func workerMessagesRoundTripWithSecureCoding() throws {
    let requestID = PipelineRequestID()
    let request = WorkerRequest(
        requestID: requestID,
        operation: .diagnosticEcho,
        modelID: "fixture-model",
        options: ["mode": "contract-test"]
    )
    let event = WorkerEvent(
        requestID: requestID,
        phase: .processing,
        progress: 0.5,
        metrics: ["elapsedMilliseconds": 12]
    )
    let failure = WorkerFailure(
        code: .protocolMismatch,
        isRetryable: false,
        underlyingCode: 42
    )
    let reply = WorkerReply(requestID: requestID, failure: failure)

    let decodedRequest = try secureRoundTrip(request, as: WorkerRequest.self)
    let decodedEvent = try secureRoundTrip(event, as: WorkerEvent.self)
    let decodedReply = try secureRoundTrip(reply, as: WorkerReply.self)

    #expect(decodedRequest.protocolVersion == KotodamaCore.protocolVersion)
    #expect(decodedRequest.requestID == requestID)
    #expect(decodedRequest.operation == .diagnosticEcho)
    #expect(decodedRequest.modelID == "fixture-model")
    #expect(decodedRequest.options == ["mode": "contract-test"])
    #expect(decodedEvent.requestID == requestID)
    #expect(decodedEvent.phase == .processing)
    #expect(decodedEvent.progress == 0.5)
    #expect(decodedEvent.metrics == ["elapsedMilliseconds": 12])
    #expect(decodedReply.requestID == requestID)
    #expect(decodedReply.failure?.code == .protocolMismatch)
    #expect(decodedReply.failure?.underlyingCode == 42)
}

private func secureRoundTrip<T: NSObject & NSSecureCoding>(
    _ value: T,
    as type: T.Type
) throws -> T {
    let data = try NSKeyedArchiver.archivedData(
        withRootObject: value,
        requiringSecureCoding: true
    )
    let decoded = try NSKeyedUnarchiver.unarchivedObject(
        ofClass: type,
        from: data
    )
    return try #require(decoded)
}

@Test func diagnosticWorkerEchoesRequestIDAndRejectsVersionMismatch() throws {
    let service = WorkerService()
    let requestID = PipelineRequestID()
    var successfulReply: WorkerReply?
    var mismatchReply: WorkerReply?

    service.perform(
        WorkerRequest(requestID: requestID, operation: .diagnosticEcho)
    ) { successfulReply = $0 }
    service.perform(
        WorkerRequest(
            protocolVersion: KotodamaCore.protocolVersion + 1,
            requestID: requestID,
            operation: .diagnosticEcho
        )
    ) { mismatchReply = $0 }

    #expect(successfulReply?.requestID == requestID)
    #expect(successfulReply?.failure == nil)
    #expect(mismatchReply?.requestID == requestID)
    #expect(mismatchReply?.failure?.code == .protocolMismatch)
}

@Test func workerShutdownReleasesProcessingAndModelBeforeReply() throws {
    let runtime = WorkerRuntimeSpy()
    let service = WorkerService(runtime: runtime)
    let requestID = PipelineRequestID()
    try runtime.load(modelID: "fixture")
    runtime.beginProcessing()
    let modelResource = WeakReference(runtime.modelResource)
    let processingResource = WeakReference(runtime.processingResource)
    var replyWasCalled = false

    service.perform(
        WorkerRequest(requestID: requestID, operation: .shutdown)
    ) { reply in
        replyWasCalled = true
        #expect(reply.failure == nil)
        #expect(modelResource.value == nil)
        #expect(processingResource.value == nil)
        #expect(runtime.events == ["cancelAll", "unload"])
    }

    #expect(replyWasCalled)
}

@Test func workerLoadStateAndUnloadStayConsistent() throws {
    let runtime = WorkerRuntimeSpy()
    let service = WorkerService(runtime: runtime)
    let loadID = PipelineRequestID()
    var loadReply: WorkerReply?
    service.perform(
        WorkerRequest(
            requestID: loadID,
            operation: .loadModel,
            modelID: "fixture"
        )
    ) { loadReply = $0 }
    #expect(loadReply?.failure == nil)

    var loadedStateReply: WorkerReply?
    service.perform(
        WorkerRequest(requestID: PipelineRequestID(), operation: .state)
    ) { loadedStateReply = $0 }
    let loadedPayload = try #require(loadedStateReply?.payload)
    let loadedSnapshot = try JSONDecoder().decode(
        WorkerSnapshot.self,
        from: loadedPayload
    )
    #expect(loadedSnapshot == WorkerSnapshot(state: .loaded, modelID: "fixture"))

    var unloadReply: WorkerReply?
    service.perform(
        WorkerRequest(requestID: PipelineRequestID(), operation: .unloadModel)
    ) { unloadReply = $0 }
    #expect(unloadReply?.failure == nil)
    #expect(runtime.modelResource == nil)
}

@Test func workerDoesNotUnloadDifferentModel() throws {
    let runtime = WorkerRuntimeSpy()
    let service = WorkerService(runtime: runtime)
    var loadReply: WorkerReply?
    service.perform(
        WorkerRequest(
            requestID: PipelineRequestID(),
            operation: .loadModel,
            modelID: "loaded-model"
        )
    ) { loadReply = $0 }
    #expect(loadReply?.failure == nil)
    runtime.resetEvents()

    var unloadReply: WorkerReply?
    service.perform(
        WorkerRequest(
            requestID: PipelineRequestID(),
            operation: .unloadModel,
            modelID: "different-model"
        )
    ) { unloadReply = $0 }

    #expect(unloadReply?.failure == nil)
    #expect(runtime.modelResource != nil)
    #expect(runtime.events.isEmpty)
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private final class WorkerRuntimeSpy: WorkerRuntimeManaging {
    final class Resource {}

    private(set) var modelResource: Resource?
    private(set) var processingResource: Resource?
    private(set) var events: [String] = []

    func load(modelID: String) throws {
        modelResource = Resource()
    }

    func beginProcessing() {
        processingResource = Resource()
    }

    func cancel(requestID: PipelineRequestID) {
        processingResource = nil
    }

    func cancelAll() {
        events.append("cancelAll")
        processingResource = nil
    }

    func unload() {
        events.append("unload")
        modelResource = nil
    }

    func resetEvents() {
        events.removeAll()
    }
}

@Test func protocolVersionStartsAtOne() {
    #expect(KotodamaCore.protocolVersion == 1)
}

@Test func rejectsInvalidTransition() {
    var machine = PipelineStateMachine()

    #expect(throws: PipelineTransitionError.invalidTransition) {
        try machine.apply(.stopRecording(requestID: PipelineRequestID()))
    }
    #expect(machine.state == .ready)
}

@Test func ignoresRecordingRequestWhileProcessing() throws {
    let requestID = PipelineRequestID()
    var machine = PipelineStateMachine()
    try machine.apply(.beginRecording)
    try machine.apply(.stopRecording(requestID: requestID))

    let result = try machine.apply(.beginRecording)

    #expect(result == .ignoredBusy)
    #expect(machine.state == .transcribing(requestID))
}

@Test func rejectsMismatchedRequestID() throws {
    let activeRequestID = PipelineRequestID()
    let unrelatedRequestID = PipelineRequestID()
    var machine = PipelineStateMachine()
    try machine.apply(.beginRecording)
    try machine.apply(.stopRecording(requestID: activeRequestID))

    #expect(throws: PipelineTransitionError.requestMismatch) {
        try machine.apply(
            .transcriptionCompleted(
                requestID: unrelatedRequestID,
                requiresFormatting: true
            )
        )
    }
    #expect(machine.state == .transcribing(activeRequestID))
}

@Test func cancellationRejectsLateCompletion() throws {
    let requestID = PipelineRequestID()
    var machine = PipelineStateMachine()
    try machine.apply(.beginRecording)
    try machine.apply(.stopRecording(requestID: requestID))
    try machine.apply(.cancel)

    #expect(machine.state == .cancelling(requestID))
    #expect(throws: PipelineTransitionError.invalidTransition) {
        try machine.apply(
            .transcriptionCompleted(
                requestID: requestID,
                requiresFormatting: false
            )
        )
    }

    try machine.apply(.cancellationCompleted(requestID: requestID))
    #expect(machine.state == .ready)
}

@Test @MainActor
func coordinatorOwnsRequestIDAndPublishesState() throws {
    let requestID = PipelineRequestID()
    let store = PipelineStore()
    let coordinator = PipelineCoordinator(
        store: store,
        makeRequestID: { requestID }
    )

    try coordinator.beginRecording()
    #expect(store.state == .recording)

    let issuedRequestID = try coordinator.stopRecording()
    #expect(issuedRequestID == requestID)
    #expect(store.state == .transcribing(requestID))

    let result = try coordinator.beginRecording()
    #expect(result == .ignoredBusy)
    #expect(store.state == .transcribing(requestID))
}

@Test func hotKeyPressGateIgnoresRepeatUntilRelease() {
    var gate = HotKeyPressGate()

    let firstPress = gate.consume(.pressed)
    let repeatedPress = gate.consume(.pressed)
    let release = gate.consume(.released)
    let nextPress = gate.consume(.pressed)

    #expect(firstPress)
    #expect(!repeatedPress)
    #expect(!release)
    #expect(nextPress)
}

@Test @MainActor
func globalHotKeyControllerEmitsOneActionPerPhysicalPress() throws {
    let backend = HotKeyBackendSpy()
    let controller = GlobalHotKeyController(backend: backend)
    var actionCount = 0
    controller.onPress = { actionCount += 1 }

    try controller.register(
        HotKeyDescriptor(keyCode: 49, modifiers: 1 << 8)
    )
    backend.emit(.pressed)
    backend.emit(.pressed)
    #expect(actionCount == 1)

    backend.emit(.released)
    backend.emit(.pressed)
    #expect(actionCount == 2)
}

@Test @MainActor
func hotKeyConflictKeepsPreviousRegistration() throws {
    let backend = HotKeyBackendSpy()
    let controller = GlobalHotKeyController(backend: backend)
    let original = HotKeyDescriptor(keyCode: 49, modifiers: 1 << 8)
    let conflicting = HotKeyDescriptor(keyCode: 11, modifiers: 1 << 8)

    try controller.register(original)
    backend.registrationError = .conflict

    #expect(throws: HotKeyRegistrationError.conflict) {
        try controller.register(conflicting)
    }
    #expect(controller.descriptor == original)
    #expect(backend.activeDescriptors == [original])
}

@Test @MainActor
func hotKeySettingsPersistOnlyAfterRegistrationSucceeds() throws {
    let backend = HotKeyBackendSpy()
    let controller = GlobalHotKeyController(backend: backend)
    let original = HotKeyDescriptor(keyCode: 49, modifiers: 1 << 8)
    let conflicting = HotKeyDescriptor(keyCode: 11, modifiers: 1 << 8)
    let persistence = HotKeyPreferenceSpy(stored: original)
    let settings = HotKeySettingsStore(
        controller: controller,
        persistence: persistence,
        defaultDescriptor: original
    )

    try settings.activate()
    backend.registrationError = .conflict
    settings.update(to: conflicting)

    #expect(settings.descriptor == original)
    #expect(settings.registrationError == .conflict)
    #expect(persistence.stored == original)
    #expect(persistence.saveCount == 0)
    #expect(backend.activeDescriptors == [original])
}

@Test @MainActor
func hotKeySettingsSaveSuccessfulRegistration() throws {
    let backend = HotKeyBackendSpy()
    let controller = GlobalHotKeyController(backend: backend)
    let original = HotKeyDescriptor(keyCode: 49, modifiers: 1 << 8)
    let replacement = HotKeyDescriptor(keyCode: 11, modifiers: 1 << 9)
    let persistence = HotKeyPreferenceSpy(stored: original)
    let settings = HotKeySettingsStore(
        controller: controller,
        persistence: persistence,
        defaultDescriptor: original
    )

    try settings.activate()
    settings.update(to: replacement)

    #expect(settings.descriptor == replacement)
    #expect(settings.registrationError == nil)
    #expect(persistence.stored == replacement)
    #expect(persistence.saveCount == 1)
    #expect(backend.activeDescriptors == [replacement])
}

@MainActor
private final class HotKeyBackendSpy: HotKeyRegistering {
    var eventHandler: ((HotKeyRegistrationToken, HotKeyEvent) -> Void)?
    var registrationError: HotKeyRegistrationError?
    private(set) var activeDescriptors: [HotKeyDescriptor] = []
    private var latestToken: HotKeyRegistrationToken?

    func register(
        _ descriptor: HotKeyDescriptor
    ) throws -> HotKeyRegistrationToken {
        if let registrationError {
            throw registrationError
        }
        activeDescriptors.append(descriptor)
        let token = HotKeyRegistrationToken()
        latestToken = token
        return token
    }

    func unregister(_ token: HotKeyRegistrationToken) {
        guard !activeDescriptors.isEmpty else {
            return
        }
        activeDescriptors.removeFirst()
    }

    func emit(_ event: HotKeyEvent) {
        guard let latestToken else { return }
        eventHandler?(latestToken, event)
    }
}

@MainActor
private final class HotKeyPreferenceSpy: HotKeyPreferencePersisting {
    var stored: HotKeyDescriptor?
    private(set) var saveCount = 0

    init(stored: HotKeyDescriptor?) {
        self.stored = stored
    }

    func load() -> HotKeyDescriptor? {
        stored
    }

    func save(_ descriptor: HotKeyDescriptor) {
        stored = descriptor
        saveCount += 1
    }
}

@Test @MainActor
func workerConnectionTimesOutAndIgnoresLateReply() async {
    let transport = WorkerTransportSpy()
    let logger = DiagnosticLoggerSpy()
    let manager = WorkerConnectionManager(
        makeTransport: { transport },
        logger: logger
    )
    let request = WorkerRequest(
        requestID: PipelineRequestID(),
        operation: .diagnosticEcho
    )

    await #expect(throws: WorkerConnectionError.timedOut) {
        try await manager.perform(request, timeout: .milliseconds(10))
    }
    transport.reply(to: request.requestID)
    #expect(logger.records.map(\.stage) == [.requested, .timedOut])
}

@Test func workerLogsTraceableMetadataForSuccessAndFailure() {
    let logger = DiagnosticLoggerSpy()
    let service = WorkerService(
        runtime: WorkerRuntimeSpy(),
        logger: logger,
        component: .speechWorker
    )
    let successID = PipelineRequestID()
    let failureID = PipelineRequestID()

    service.perform(
        WorkerRequest(
            requestID: successID,
            operation: .diagnosticEcho,
            options: ["canary": "must-not-enter-log-record"]
        )
    ) { _ in }
    service.perform(
        WorkerRequest(
            protocolVersion: KotodamaCore.protocolVersion + 1,
            requestID: failureID,
            operation: .diagnosticEcho
        )
    ) { _ in }

    #expect(logger.records.map(\.requestID) == [
        successID, successID, failureID, failureID,
    ])
    #expect(logger.records.map(\.stage) == [
        .accepted, .completed, .accepted, .failed,
    ])
    #expect(logger.records.last?.failureCode == .protocolMismatch)
}

@Test @MainActor
func workerInterruptionFailsOnceAndCreatesNewConnection() async throws {
    let first = WorkerTransportSpy()
    let second = WorkerTransportSpy()
    var transports = [first, second]
    let manager = WorkerConnectionManager(
        makeTransport: { transports.removeFirst() }
    )
    let request = WorkerRequest(
        requestID: PipelineRequestID(),
        operation: .diagnosticEcho
    )
    let task = Task {
        try await manager.perform(request, timeout: .seconds(1))
    }
    await Task.yield()

    first.interrupt()

    await #expect(throws: WorkerConnectionError.interrupted) {
        try await task.value
    }
    first.reply(to: request.requestID)

    let retryRequest = WorkerRequest(
        requestID: PipelineRequestID(),
        operation: .diagnosticEcho
    )
    let retryTask = Task {
        try await manager.perform(retryRequest, timeout: .seconds(1))
    }
    await Task.yield()
    second.reply(to: retryRequest.requestID)

    let reply = try await retryTask.value
    #expect(reply.requestID == retryRequest.requestID)
    #expect(first.activationCount == 1)
    #expect(second.activationCount == 1)
}

@Test @MainActor
func workerInvalidationCreatesNewConnectionForNextRequest() async throws {
    let first = WorkerTransportSpy()
    let second = WorkerTransportSpy()
    var transports: [WorkerTransportSpy] = [first, second]
    let manager = WorkerConnectionManager(
        makeTransport: { transports.removeFirst() }
    )
    let firstRequest = WorkerRequest(
        requestID: PipelineRequestID(),
        operation: .diagnosticEcho
    )
    let firstTask = Task {
        try await manager.perform(firstRequest, timeout: .seconds(1))
    }
    await Task.yield()
    first.invalidateConnection()
    await #expect(throws: WorkerConnectionError.invalidated) {
        try await firstTask.value
    }

    let secondRequest = WorkerRequest(
        requestID: PipelineRequestID(),
        operation: .diagnosticEcho
    )
    let secondTask = Task {
        try await manager.perform(secondRequest, timeout: .seconds(1))
    }
    await Task.yield()
    second.reply(to: secondRequest.requestID)

    let reply = try await secondTask.value
    #expect(reply.requestID == secondRequest.requestID)
    #expect(first.activationCount == 1)
    #expect(second.activationCount == 1)
}

@Test @MainActor
func workerCancellationCancelsOnlyActiveRequest() async {
    let transport = WorkerTransportSpy()
    let manager = WorkerConnectionManager(makeTransport: { transport })
    let request = WorkerRequest(
        requestID: PipelineRequestID(),
        operation: .diagnosticEcho
    )
    let task = Task {
        try await manager.perform(request, timeout: .seconds(1))
    }
    await Task.yield()

    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(transport.cancelledRequestIDs == [request.requestID])
}

@MainActor
private final class WorkerTransportSpy: WorkerTransport {
    var interruptionHandler: (@MainActor @Sendable () -> Void)?
    var invalidationHandler: (@MainActor @Sendable () -> Void)?
    private(set) var activationCount = 0
    private(set) var cancelledRequestIDs: [PipelineRequestID] = []
    private var replies: [
        PipelineRequestID: @MainActor @Sendable (WorkerReply) -> Void
    ] = [:]

    func activate() {
        activationCount += 1
    }

    func send(
        _ request: WorkerRequest,
        reply: @escaping @MainActor @Sendable (WorkerReply) -> Void
    ) {
        replies[request.requestID] = reply
    }

    func cancel(requestID: PipelineRequestID) {
        cancelledRequestIDs.append(requestID)
    }

    func invalidate() {}

    func interrupt() {
        interruptionHandler?()
    }

    func invalidateConnection() {
        invalidationHandler?()
    }

    func reply(to requestID: PipelineRequestID) {
        replies[requestID]?(WorkerReply(requestID: requestID))
    }
}

private final class DiagnosticLoggerSpy: DiagnosticLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRecords: [DiagnosticRecord] = []

    var records: [DiagnosticRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storedRecords
    }

    func record(_ record: DiagnosticRecord) {
        lock.lock()
        storedRecords.append(record)
        lock.unlock()
    }
}
