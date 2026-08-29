import AVFoundation
import Foundation
import KotodamaCore
import Testing
@testable import KotodamaVoice

@Suite(.serialized)
@MainActor
struct LocalSpeechOfflineIntegrationTests {
    @Test
    func installedModelTranscribesWithoutOpeningNetworkSockets() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KOTODAMA_OFFLINE_REQUIRED"] == "1" else {
            return
        }
        let modelPath = try #require(environment["KOTODAMA_OFFLINE_MODEL"])
        let audioPath = try #require(environment["KOTODAMA_OFFLINE_AUDIO"])

        let catalog = ModelCatalog()
        let model = try #require(catalog.models.first {
            $0.purpose == .speech && $0.isDefault
        })
        let installedModel = try installVerifiedFixture(
            sourceURL: URL(fileURLWithPath: modelPath),
            model: model
        )
        defer { installedModel.cleanUp() }

        let buffer = try readAudioBuffer(
            at: URL(fileURLWithPath: audioPath)
        )
        let requestID = PipelineRequestID()
        let store = PipelineStore(initialState: .recording)
        let coordinator = PipelineCoordinator(
            store: store,
            makeRequestID: { requestID }
        )
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "KotodamaVoiceOfflineIntegration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let speechClient = SpeechWorkerClient()
        let pipeline = LocalSpeechPipeline(
            store: store,
            coordinator: coordinator,
            recorder: OfflineAudioRecorder(buffer: buffer),
            temporaryAudioStore: TemporaryAudioStore(rootURL: temporaryRoot),
            speech: speechClient
        )

        let workerPID = try await speechWorkerProcessIdentifier()
        let control = SocketMonitorControl()
        let monitor = Task.detached {
            try await monitorIPSockets(
                processIdentifier: workerPID,
                control: control
            )
        }
        let transcription: LocalTranscription
        do {
            transcription = try await pipeline.stopAndTranscribe(
                modelID: model.id
            )
        } catch {
            await control.stop()
            _ = try? await monitor.value
            throw error
        }
        await control.stop()
        let observedNetworkSocket = try await monitor.value
        try await speechClient.unload()

        #expect(transcription.requestID == requestID)
        #expect(!transcription.text.isEmpty)
        #expect(store.state == .transcribing(requestID))
        #expect(!observedNetworkSocket)
        let remainingTemporaryFiles = try FileManager.default
            .contentsOfDirectory(atPath: temporaryRoot.path)
        #expect(remainingTemporaryFiles.isEmpty)
    }

    @Test
    func workerTerminationFailsOnceThenNextRecordingRecovers() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KOTODAMA_OFFLINE_REQUIRED"] == "1" else {
            return
        }
        let modelPath = try #require(environment["KOTODAMA_OFFLINE_MODEL"])
        let audioPath = try #require(environment["KOTODAMA_OFFLINE_AUDIO"])
        let model = try #require(ModelCatalog().models.first {
            $0.purpose == .speech && $0.isDefault
        })
        let installedModel = try installVerifiedFixture(
            sourceURL: URL(fileURLWithPath: modelPath),
            model: model
        )
        defer { installedModel.cleanUp() }
        let buffer = try readAudioBuffer(
            at: URL(fileURLWithPath: audioPath)
        )
        let speechClient = SpeechWorkerClient()
        let preloadRoot = FileManager.default.temporaryDirectory.appending(
            path: "KotodamaVoiceCrashPreload-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let preloadStore = TemporaryAudioStore(rootURL: preloadRoot)
        let preloadLease = try preloadStore.createLease(
            requestID: PipelineRequestID(),
            buffer: buffer
        )
        defer {
            preloadLease.release()
            try? FileManager.default.removeItem(at: preloadRoot)
        }
        _ = try await speechClient.transcribe(
            modelID: model.id,
            audioInput: preloadLease.audioInput,
            requestID: PipelineRequestID()
        )
        preloadLease.release()

        let terminatedProcessID = try await speechWorkerProcessIdentifier()
        let failedRequestID = PipelineRequestID()
        let recoveredRequestID = PipelineRequestID()
        var requestIDs = [failedRequestID, recoveredRequestID]
        let store = PipelineStore(initialState: .recording)
        let coordinator = PipelineCoordinator(
            store: store,
            makeRequestID: { requestIDs.removeFirst() }
        )
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "KotodamaVoiceCrashRecovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let pipeline = LocalSpeechPipeline(
            store: store,
            coordinator: coordinator,
            recorder: OfflineAudioRecorder(buffer: buffer),
            temporaryAudioStore: TemporaryAudioStore(rootURL: temporaryRoot),
            speech: speechClient
        )

        let interruptedRequest = Task { @MainActor in
            try await pipeline.stopAndTranscribe(modelID: model.id)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(kill(terminatedProcessID, SIGKILL) == 0)
        do {
            _ = try await interruptedRequest.value
            Issue.record("推論中に終了したWorkerの要求が成功しました")
        } catch let error as WorkerConnectionError {
            #expect(error == .interrupted || error == .invalidated)
        }
        try await waitForProcessTermination(terminatedProcessID)
        #expect(store.state == .failed(failedRequestID))

        _ = try coordinator.recover()
        _ = try coordinator.beginRecording()
        let recovered = try await pipeline.stopAndTranscribe(modelID: model.id)
        try await speechClient.unload()

        #expect(recovered.requestID == recoveredRequestID)
        #expect(!recovered.text.isEmpty)
        #expect(store.state == .transcribing(recoveredRequestID))
    }

    private func installVerifiedFixture(
        sourceURL: URL,
        model: ModelManifestEntry
    ) throws -> InstalledModelFixture {
        let storage = FoundationModelStorage()
        #expect(try storage.fileSize(at: sourceURL) == model.byteCount)
        #expect(try storage.sha256(at: sourceURL) == model.sha256)
        let containerURL = try #require(
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier:
                    "group.com.tsuyukimakoto.KotodamaVoice"
            )
        )
        let directoryURL = containerURL
            .appending(path: "Models", directoryHint: .isDirectory)
            .appending(path: model.id, directoryHint: .isDirectory)
        let destinationURL = directoryURL.appending(
            path: model.fileName,
            directoryHint: .notDirectory
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            #expect(try storage.fileSize(at: destinationURL) == model.byteCount)
            #expect(try storage.sha256(at: destinationURL) == model.sha256)
            return InstalledModelFixture(directoryURL: directoryURL, ownsCopy: false)
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
        return InstalledModelFixture(directoryURL: directoryURL, ownsCopy: true)
    }

    private func readAudioBuffer(at url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        #expect(format.commonFormat == .pcmFormatFloat32)
        #expect(!format.isInterleaved)
        #expect(format.channelCount == 1)
        #expect(format.sampleRate == 16_000)
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        )
        try file.read(into: buffer)
        return buffer
    }

    private func speechWorkerProcessIdentifier() async throws -> pid_t {
        let reply = try await WorkerDiagnosticClient().echo(.speech)
        let payload = try #require(reply.payload)
        return try JSONDecoder().decode(
            OfflineWorkerProcess.self,
            from: payload
        ).processIdentifier
    }

    private func waitForProcessTermination(_ processIdentifier: pid_t) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while kill(processIdentifier, 0) == 0 {
            guard ContinuousClock.now < deadline else {
                throw OfflineWorkerTerminationError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class OfflineAudioRecorder: AudioRecordingManaging {
    private let buffer: AVAudioPCMBuffer

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func start() throws {}
    func stop() throws -> AVAudioPCMBuffer { buffer }
    func cancel() {}
}

private struct InstalledModelFixture {
    let directoryURL: URL
    let ownsCopy: Bool

    func cleanUp() {
        guard ownsCopy else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct OfflineWorkerProcess: Decodable {
    let processIdentifier: pid_t
}

private actor SocketMonitorControl {
    private var isStopped = false

    func stop() {
        isStopped = true
    }

    func shouldContinue() -> Bool {
        !isStopped
    }
}

private func monitorIPSockets(
    processIdentifier: pid_t,
    control: SocketMonitorControl
) async throws -> Bool {
    repeat {
        if try processHasIPSocket(processIdentifier) {
            return true
        }
        try await Task.sleep(for: .milliseconds(20))
    } while await control.shouldContinue()
    return try processHasIPSocket(processIdentifier)
}

private func processHasIPSocket(_ processIdentifier: pid_t) throws -> Bool {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = [
        "-nP",
        "-a",
        "-p",
        String(processIdentifier),
        "-i",
    ]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
        throw SocketMonitorError.lsofFailed(process.terminationStatus)
    }
    let data = try output.fileHandleForReading.readToEnd() ?? Data()
    return process.terminationStatus == 0 && !data.isEmpty
}

private enum SocketMonitorError: Error {
    case lsofFailed(Int32)
}

private enum OfflineWorkerTerminationError: Error {
    case timedOut
}
