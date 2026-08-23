import Foundation
import KotodamaCore
import whisper

final class SpeechWorkerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: WorkerServiceProtocol.self
        )
        newConnection.exportedObject = WorkerService(
            runtime: SpeechRuntimePlaceholder(),
            logger: OSLogDiagnosticLogger(component: .speechWorker),
            component: .speechWorker
        )
        newConnection.activate()
        return true
    }
}

private final class SpeechRuntimePlaceholder: WorkerRuntimeManaging {
    func load(modelID: String) throws {}
    func cancel(requestID: PipelineRequestID) {}
    func cancelAll() {}
    func unload() {}
}

let delegate = SpeechWorkerDelegate()
_ = whisper_context_default_params()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
