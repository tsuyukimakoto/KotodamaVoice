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

@Test func workerMonitorSnapshotRoundTripsWithoutContent() throws {
    let requestID = PipelineRequestID()
    let snapshot = WorkerSnapshot(
        state: .loaded,
        modelID: "fixture-model",
        processIdentifier: 321,
        usesMetal: true,
        lastRequest: WorkerLastRequestSnapshot(
            requestID: requestID,
            result: .succeeded,
            processingMilliseconds: 125,
            promptTokensPerSecond: 48,
            generationTokensPerSecond: 12
        )
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(WorkerSnapshot.self, from: data)

    #expect(decoded == snapshot)
    #expect(decoded.lastRequest?.requestID == requestID)
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
    #expect(loadedSnapshot.state == .loaded)
    #expect(loadedSnapshot.modelID == "fixture")
    #expect(
        loadedSnapshot.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
    )

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

@Test func workerStateIncludesLatestRequestMetrics() throws {
    let runtime = MonitoredFormatterRuntimeSpy()
    let service = WorkerService(runtime: runtime)
    service.perform(
        WorkerRequest(
            requestID: PipelineRequestID(),
            operation: .loadModel,
            modelID: "formatter"
        )
    ) { _ in }
    let requestID = PipelineRequestID()
    service.perform(
        WorkerRequest(
            requestID: requestID,
            operation: .format,
            options: ["text": "input", "prompt": "prompt"]
        )
    ) { reply in
        #expect(reply.failure == nil)
    }

    var stateReply: WorkerReply?
    service.perform(
        WorkerRequest(requestID: PipelineRequestID(), operation: .state)
    ) { stateReply = $0 }
    let payload = try #require(stateReply?.payload)
    let snapshot = try JSONDecoder().decode(WorkerSnapshot.self, from: payload)

    #expect(snapshot.usesMetal == true)
    #expect(snapshot.lastRequest?.requestID == requestID)
    #expect(snapshot.lastRequest?.result == .succeeded)
    #expect(snapshot.lastRequest?.processingMilliseconds ?? -1 >= 0)
    #expect(snapshot.lastRequest?.promptTokensPerSecond == 40)
    #expect(snapshot.lastRequest?.generationTokensPerSecond == 10)
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private final class MonitoredFormatterRuntimeSpy: TextFormattingRuntime,
    WorkerRuntimeMetricsProviding
{
    var workerRuntimeMetrics: WorkerRuntimeMetrics {
        WorkerRuntimeMetrics(
            usesMetal: true,
            promptTokensPerSecond: 40,
            generationTokensPerSecond: 10
        )
    }

    func load(modelID: String) throws {}
    func cancel(requestID: PipelineRequestID) {}
    func cancelAll() {}
    func unload() {}

    func format(
        text: String,
        prompt: String,
        requestID: PipelineRequestID
    ) throws -> String {
        "formatted"
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

@Test func protocolVersionSupportsGlossaryContract() {
    #expect(KotodamaCore.protocolVersion == 3)
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
    #expect(transport.cancelledRequestIDs == [request.requestID])
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

    #expect(
        logger.records.map(\.requestID) == [
            successID, successID, failureID, failureID,
        ])
    #expect(
        logger.records.map(\.stage) == [
            .accepted, .completed, .accepted, .failed,
        ])
    #expect(logger.records.last?.failureCode == .protocolMismatch)
}

@Test func workerFailureDiagnosticsAndMonitorExcludeSensitiveCanaries() throws {
    let canaries = [
        "kv-audio-canary",
        "kv-transcription-canary",
        "kv-prompt-canary",
        "kv-formatted-canary",
        "kv-clipboard-canary",
        "kv-api-key-canary",
    ]
    let logger = DiagnosticLoggerSpy()
    let runtime = PrivacyCanaryFormatterRuntime()
    let service = WorkerService(
        runtime: runtime,
        logger: logger,
        component: .formatterWorker
    )
    service.perform(
        WorkerRequest(
            requestID: PipelineRequestID(),
            operation: .loadModel,
            modelID: "formatter"
        )
    ) { _ in }

    for failure in [
        WorkerRuntimeError.cancelled,
        .invalidInput,
        .processingFailed,
    ] {
        runtime.nextFailure = failure
        service.perform(
            WorkerRequest(
                requestID: PipelineRequestID(),
                operation: .format,
                options: [
                    "text": canaries[1],
                    "prompt": canaries[2],
                    "audio": canaries[0],
                    "formatted": canaries[3],
                    "clipboard": canaries[4],
                    "apiKey": canaries[5],
                ]
            )
        ) { _ in }
    }

    var stateReply: WorkerReply?
    service.perform(
        WorkerRequest(requestID: PipelineRequestID(), operation: .state)
    ) { stateReply = $0 }
    let monitorPayload = try #require(stateReply?.payload)
    let observableOutput =
        logger.records.map(\.osLogMessage).joined()
        + String(decoding: monitorPayload, as: UTF8.self)

    for canary in canaries {
        #expect(!observableOutput.contains(canary))
    }
}

@Test @MainActor
func connectionFailureDiagnosticsExcludeRequestContent() async {
    let canary = "kv-all-connection-failures-canary"
    let logger = DiagnosticLoggerSpy()

    do {
        let transport = WorkerTransportSpy()
        let manager = WorkerConnectionManager(
            makeTransport: { transport },
            logger: logger
        )
        let request = privacyCanaryRequest(canary)
        await #expect(throws: WorkerConnectionError.timedOut) {
            try await manager.perform(request, timeout: .milliseconds(1))
        }
    }
    do {
        let transport = WorkerTransportSpy()
        let manager = WorkerConnectionManager(
            makeTransport: { transport },
            logger: logger
        )
        let request = privacyCanaryRequest(canary)
        let task = Task {
            try await manager.perform(request, timeout: .seconds(1))
        }
        await Task.yield()
        transport.interrupt()
        await #expect(throws: WorkerConnectionError.interrupted) {
            try await task.value
        }
    }
    do {
        let transport = WorkerTransportSpy()
        let manager = WorkerConnectionManager(
            makeTransport: { transport },
            logger: logger
        )
        let request = privacyCanaryRequest(canary)
        let task = Task {
            try await manager.perform(request, timeout: .seconds(1))
        }
        await Task.yield()
        transport.invalidateConnection()
        await #expect(throws: WorkerConnectionError.invalidated) {
            try await task.value
        }
    }
    do {
        let transport = WorkerTransportSpy()
        let manager = WorkerConnectionManager(
            makeTransport: { transport },
            logger: logger
        )
        let request = privacyCanaryRequest(canary)
        let task = Task {
            try await manager.perform(request, timeout: .seconds(1))
        }
        await Task.yield()
        transport.reply(
            WorkerReply(
                protocolVersion: KotodamaCore.protocolVersion + 1,
                requestID: request.requestID
            ),
            to: request.requestID
        )
        await #expect(throws: WorkerConnectionError.protocolMismatch) {
            try await task.value
        }
    }
    do {
        let transport = WorkerTransportSpy()
        let manager = WorkerConnectionManager(
            makeTransport: { transport },
            logger: logger
        )
        let request = privacyCanaryRequest(canary)
        let task = Task {
            try await manager.perform(request, timeout: .seconds(1))
        }
        await Task.yield()
        transport.reply(
            WorkerReply(requestID: PipelineRequestID()),
            to: request.requestID
        )
        await #expect(throws: WorkerConnectionError.requestMismatch) {
            try await task.value
        }
    }
    do {
        let transport = WorkerTransportSpy()
        let manager = WorkerConnectionManager(
            makeTransport: { transport },
            logger: logger
        )
        let request = privacyCanaryRequest(canary)
        let task = Task {
            try await manager.perform(request, timeout: .seconds(1))
        }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    let messages = logger.records.map(\.osLogMessage).joined()
    #expect(!messages.contains(canary))
    #expect(
        Set(logger.records.map(\.stage)).isSuperset(of: [
            .timedOut, .interrupted, .invalidated, .failed, .cancelled,
        ]))
}

@Test @MainActor
func requestTraceCorrelatesAppWorkersStagesAndElapsedTime() async throws {
    let logger = DiagnosticLoggerSpy()
    let normalService = WorkerService(
        runtime: WorkerRuntimeSpy(),
        logger: logger,
        component: .speechWorker
    )
    let normalManager = WorkerConnectionManager(
        makeTransport: { InProcessWorkerTransport(service: normalService) },
        logger: logger
    )
    let normalID = PipelineRequestID()

    _ = try await normalManager.perform(
        WorkerRequest(requestID: normalID, operation: .diagnosticEcho),
        timeout: .seconds(1)
    )

    let normalTrace = logger.records.filter { $0.requestID == normalID }
    #expect(
        normalTrace.map(\.component) == [
            .app, .speechWorker, .speechWorker, .app,
        ])
    #expect(
        normalTrace.map(\.stage) == [
            .requested, .accepted, .completed, .completed,
        ])
    #expect(normalTrace[2].elapsedMilliseconds ?? -1 >= 0)
    #expect(normalTrace[3].elapsedMilliseconds ?? -1 >= 0)

    for component in [
        DiagnosticComponent.speechWorker,
        .formatterWorker,
    ] {
        let manager = WorkerConnectionManager(
            makeTransport: {
                AcceptedThenInterruptedTransport(
                    logger: logger,
                    component: component
                )
            },
            logger: logger
        )
        let crashID = PipelineRequestID()

        await #expect(throws: WorkerConnectionError.interrupted) {
            try await manager.perform(
                WorkerRequest(
                    requestID: crashID,
                    operation: component == .speechWorker
                        ? .transcribe
                        : .format
                ),
                timeout: .seconds(1)
            )
        }

        let crashTrace = logger.records.filter { $0.requestID == crashID }
        #expect(crashTrace.map(\.component) == [.app, component, .app])
        #expect(
            crashTrace.map(\.stage) == [
                .requested, .accepted, .interrupted,
            ])
        #expect(crashTrace[2].elapsedMilliseconds ?? -1 >= 0)
    }
}

private func privacyCanaryRequest(_ canary: String) -> WorkerRequest {
    WorkerRequest(
        requestID: PipelineRequestID(),
        operation: .format,
        options: ["text": canary, "prompt": canary]
    )
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
    private var replies: [PipelineRequestID: @MainActor @Sendable (WorkerReply) -> Void] = [:]

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

    func reply(_ reply: WorkerReply, to requestID: PipelineRequestID) {
        replies[requestID]?(reply)
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

private final class PrivacyCanaryFormatterRuntime: TextFormattingRuntime {
    var nextFailure: WorkerRuntimeError = .processingFailed

    func load(modelID: String) throws {}
    func cancel(requestID: PipelineRequestID) {}
    func cancelAll() {}
    func unload() {}

    func format(
        text: String,
        prompt: String,
        requestID: PipelineRequestID
    ) throws -> String {
        throw nextFailure
    }
}

@MainActor
private final class InProcessWorkerTransport: WorkerTransport {
    var interruptionHandler: (@MainActor @Sendable () -> Void)?
    var invalidationHandler: (@MainActor @Sendable () -> Void)?
    private let service: WorkerService

    init(service: WorkerService) {
        self.service = service
    }

    func activate() {}

    func send(
        _ request: WorkerRequest,
        reply: @escaping @MainActor @Sendable (WorkerReply) -> Void
    ) {
        service.perform(request, withReply: reply)
    }

    func cancel(requestID: PipelineRequestID) {}
    func invalidate() {}
}

@MainActor
private final class AcceptedThenInterruptedTransport: WorkerTransport {
    var interruptionHandler: (@MainActor @Sendable () -> Void)?
    var invalidationHandler: (@MainActor @Sendable () -> Void)?
    private let logger: DiagnosticLogging
    private let component: DiagnosticComponent

    init(logger: DiagnosticLogging, component: DiagnosticComponent) {
        self.logger = logger
        self.component = component
    }

    func activate() {}

    func send(
        _ request: WorkerRequest,
        reply: @escaping @MainActor @Sendable (WorkerReply) -> Void
    ) {
        logger.record(
            DiagnosticRecord(
                component: component,
                requestID: request.requestID,
                operation: request.operation,
                stage: .accepted
            )
        )
        interruptionHandler?()
    }

    func cancel(requestID: PipelineRequestID) {}
    func invalidate() {}
}
