import Darwin
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

struct WorkerProcessResources: Equatable {
    let physicalFootprintBytes: UInt64?
    let cpuPercentage: Double?
}

struct WorkerMonitorSnapshot: Equatable {
    let worker: WorkerSnapshot
    let resources: WorkerProcessResources?
}

enum WorkerDiagnosticState: Equatable {
    case disconnected
    case checking
    case connected(WorkerMonitorSnapshot)
    case failed
}

@MainActor
protocol WorkerMonitoring: AnyObject {
    func snapshot(for endpoint: WorkerEndpoint) async throws -> WorkerSnapshot
}

@MainActor
final class WorkerDiagnosticClient: WorkerMonitoring {
    private lazy var managers: [WorkerEndpoint: WorkerConnectionManager] = [
        .speech: makeManager(for: .speech),
        .formatter: makeManager(for: .formatter),
    ]

    func echo(
        _ endpoint: WorkerEndpoint,
        requestID: PipelineRequestID = PipelineRequestID(),
        timeout: Duration = .seconds(3)
    ) async throws -> WorkerReply {
        try await perform(
            WorkerRequest(requestID: requestID, operation: .diagnosticEcho),
            in: endpoint,
            timeout: timeout
        )
    }

    func snapshot(for endpoint: WorkerEndpoint) async throws -> WorkerSnapshot {
        let reply = try await perform(
            WorkerRequest(requestID: PipelineRequestID(), operation: .state),
            in: endpoint,
            timeout: .seconds(3)
        )
        guard reply.failure == nil, let payload = reply.payload else {
            throw WorkerDiagnosticError.invalidSnapshot
        }
        return try JSONDecoder().decode(WorkerSnapshot.self, from: payload)
    }

    func hasActiveConnection(to endpoint: WorkerEndpoint) -> Bool {
        managers[endpoint]?.hasActiveTransport == true
    }

    func mapDiagnosticFixture(
        in endpoint: WorkerEndpoint
    ) async throws -> WorkerReply {
        try await perform(
            WorkerRequest(
                requestID: PipelineRequestID(),
                operation: .diagnosticMapFixture
            ),
            in: endpoint,
            timeout: .seconds(3)
        )
    }

    private func perform(
        _ request: WorkerRequest,
        in endpoint: WorkerEndpoint,
        timeout: Duration
    ) async throws -> WorkerReply {
        guard let manager = managers[endpoint] else {
            throw WorkerDiagnosticError.invalidEndpoint
        }
        return try await manager.perform(request, timeout: timeout)
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
    case invalidSnapshot
}

@MainActor
protocol WorkerProcessSampling: AnyObject {
    func sample(processIdentifier: Int32) -> WorkerProcessResources?
    func reset()
}

@MainActor
final class SystemWorkerProcessSampler: WorkerProcessSampling {
    private struct PreviousSample {
        let cpuNanoseconds: UInt64
        let systemUptime: TimeInterval
    }

    private var previousSamples: [Int32: PreviousSample] = [:]

    func sample(processIdentifier: Int32) -> WorkerProcessResources? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(processIdentifier, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else {
            previousSamples[processIdentifier] = nil
            return nil
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        let cpuNanoseconds = usage.ri_user_time + usage.ri_system_time
        let cpuPercentage: Double?
        if let previous = previousSamples[processIdentifier],
            uptime > previous.systemUptime,
            cpuNanoseconds >= previous.cpuNanoseconds
        {
            cpuPercentage = Double(cpuNanoseconds - previous.cpuNanoseconds)
                / 1_000_000_000
                / (uptime - previous.systemUptime)
                * 100
        } else {
            cpuPercentage = nil
        }
        previousSamples[processIdentifier] = PreviousSample(
            cpuNanoseconds: cpuNanoseconds,
            systemUptime: uptime
        )
        return WorkerProcessResources(
            physicalFootprintBytes: usage.ri_phys_footprint,
            cpuPercentage: cpuPercentage
        )
    }

    func reset() {
        previousSamples.removeAll()
    }
}

@MainActor
protocol RuntimeMonitorCancellable: AnyObject {
    func cancel()
}

@MainActor
protocol RuntimeMonitorScheduling: AnyObject {
    func schedule(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> RuntimeMonitorCancellable
}

@MainActor
final class TaskRuntimeMonitorScheduler: RuntimeMonitorScheduling {
    func schedule(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> RuntimeMonitorCancellable {
        RuntimeMonitorTaskCancellation(
            task: Task { @MainActor in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        break
                    }
                    guard !Task.isCancelled else { break }
                    action()
                }
            }
        )
    }
}

@MainActor
private final class RuntimeMonitorTaskCancellation: RuntimeMonitorCancellable {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

@Observable
@MainActor
final class WorkerDiagnostics {
    private(set) var states: [WorkerEndpoint: WorkerDiagnosticState] = [
        .speech: .disconnected,
        .formatter: .disconnected,
    ]

    private let client: WorkerMonitoring
    private let processSampler: WorkerProcessSampling
    private let scheduler: RuntimeMonitorScheduling
    private var polling: RuntimeMonitorCancellable?
    private var refreshGeneration = 0
    private var pendingRefreshes: [Task<Void, Never>] = []
    private(set) var isMonitoring = false

    init(
        client: WorkerMonitoring = WorkerDiagnosticClient(),
        processSampler: WorkerProcessSampling = SystemWorkerProcessSampler(),
        scheduler: RuntimeMonitorScheduling = TaskRuntimeMonitorScheduler()
    ) {
        self.client = client
        self.processSampler = processSampler
        self.scheduler = scheduler
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        refresh()
        polling = scheduler.schedule { [weak self] in
            self?.refresh()
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        refreshGeneration += 1
        polling?.cancel()
        polling = nil
        pendingRefreshes.forEach { $0.cancel() }
        pendingRefreshes.removeAll()
        processSampler.reset()
    }

    func checkAll() {
        refresh()
    }

    func refresh() {
        guard isMonitoring else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        pendingRefreshes.forEach { $0.cancel() }
        pendingRefreshes = WorkerEndpoint.allCases.map { endpoint in
            states[endpoint] = .checking
            return Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let workerSnapshot = try await client.snapshot(for: endpoint)
                    guard isMonitoring, generation == refreshGeneration else {
                        return
                    }
                    let resources = processSampler.sample(
                        processIdentifier: workerSnapshot.processIdentifier
                    )
                    states[endpoint] = .connected(
                        WorkerMonitorSnapshot(
                            worker: workerSnapshot,
                            resources: resources
                        )
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard isMonitoring, generation == refreshGeneration else {
                        return
                    }
                    states[endpoint] = .failed
                }
            }
        }
    }

    func waitForPendingRefreshes() async {
        let tasks = pendingRefreshes
        for task in tasks {
            await task.value
        }
    }
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
