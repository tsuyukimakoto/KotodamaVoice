import Foundation
import KotodamaCore
import llama

final class FormatterWorkerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = WorkerService(
        runtime: FormatterRuntime(resolveModelURL: resolveFormatterModelURL),
        logger: OSLogDiagnosticLogger(component: .formatterWorker),
        component: .formatterWorker,
        diagnosticFixtureMapper: {
            try WorkerDiagnosticFixture.map(
                appGroupIdentifier: "group.com.tsuyukimakoto.KotodamaVoice"
            )
        }
    )

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: WorkerServiceProtocol.self
        )
        newConnection.exportedObject = service
        newConnection.activate()
        return true
    }
}

private func resolveFormatterModelURL(modelID: String) throws -> URL {
    guard let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.tsuyukimakoto.KotodamaVoice"
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
