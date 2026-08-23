import Foundation
import KotodamaCore
import llama

final class FormatterWorkerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: WorkerServiceProtocol.self
        )
        newConnection.exportedObject = WorkerService(
            runtime: FormatterRuntimePlaceholder(),
            logger: OSLogDiagnosticLogger(component: .formatterWorker),
            component: .formatterWorker,
            diagnosticFixtureMapper: mapAppGroupDiagnosticFixture
        )
        newConnection.activate()
        return true
    }
}

private final class FormatterRuntimePlaceholder: WorkerRuntimeManaging {
    func load(modelID: String) throws {}
    func cancel(requestID: PipelineRequestID) {}
    func cancelAll() {}
    func unload() {}
}

let delegate = FormatterWorkerDelegate()
_ = llama_model_default_params()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
