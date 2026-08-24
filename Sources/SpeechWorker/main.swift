import Foundation
import KotodamaCore
import whisper

final class SpeechWorkerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = WorkerService(
        runtime: SpeechRuntime(resolveModelURL: resolveSpeechModelURL),
        logger: OSLogDiagnosticLogger(component: .speechWorker),
        component: .speechWorker,
        diagnosticFixtureMapper: {
            try WorkerDiagnosticFixture.map(
                appGroupIdentifier: "group.jp.tsuyuki.KotodamaVoice"
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

private func resolveSpeechModelURL(modelID: String) throws -> URL {
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
    guard files.count == 1, files[0].pathExtension == "bin" else {
        throw WorkerRuntimeError.invalidInput
    }
    return files[0]
}

let delegate = SpeechWorkerDelegate()
_ = whisper_context_default_params()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
