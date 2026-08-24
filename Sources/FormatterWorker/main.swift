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
            runtime: FormatterRuntime(resolveModelURL: resolveFormatterModelURL),
            logger: OSLogDiagnosticLogger(component: .formatterWorker),
            component: .formatterWorker,
            diagnosticFixtureMapper: {
                try WorkerDiagnosticFixture.map(
                    appGroupIdentifier: "group.jp.tsuyuki.KotodamaVoice"
                )
            }
        )
        newConnection.activate()
        return true
    }
}

private func resolveFormatterModelURL(modelID: String) throws -> URL {
    guard let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.jp.tsuyuki.KotodamaVoice"
    ) else {
        throw WorkerRuntimeError.processingFailed
    }
    let modelDirectory = containerURL
        .appending(path: "Models", directoryHint: .isDirectory)
        .appending(path: modelID, directoryHint: .isDirectory)
    let files = try FileManager.default.contentsOfDirectory(
        at: modelDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    guard files.count == 1, files[0].pathExtension == "gguf" else {
        throw WorkerRuntimeError.invalidInput
    }
    return files[0]
}

let delegate = FormatterWorkerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
