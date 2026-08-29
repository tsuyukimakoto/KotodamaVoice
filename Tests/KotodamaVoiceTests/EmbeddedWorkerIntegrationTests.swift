import Foundation
import KotodamaCore
import Testing
@testable import KotodamaVoice

@Suite(.serialized)
@MainActor
struct EmbeddedWorkerIntegrationTests {
    @Test
    func workersReplyToDiagnosticEcho() async throws {
        let client = WorkerDiagnosticClient()

        for endpoint in WorkerEndpoint.allCases {
            let requestID = PipelineRequestID()
            let reply = try await client.echo(endpoint, requestID: requestID)

            #expect(reply.failure == nil)
            #expect(reply.requestID == requestID)
            #expect(reply.protocolVersion == KotodamaCore.protocolVersion)
        }
    }

    @Test
    func workersRestartAfterForcedTermination() async throws {
        let client = WorkerDiagnosticClient()

        for endpoint in WorkerEndpoint.allCases {
            let firstReply = try await client.echo(endpoint)
            let firstProcess = try JSONDecoder().decode(
                DiagnosticProcessFixture.self,
                from: try #require(firstReply.payload)
            )

            #expect(kill(firstProcess.processIdentifier, SIGKILL) == 0)
            try await waitUntilProcessTerminates(
                firstProcess.processIdentifier
            )
            try await waitUntilConnectionIsDiscarded(
                by: client,
                endpoint: endpoint
            )

            let secondReply = try await client.echo(
                endpoint,
                timeout: .seconds(15)
            )
            let secondProcess = try JSONDecoder().decode(
                DiagnosticProcessFixture.self,
                from: try #require(secondReply.payload)
            )
            #expect(
                secondProcess.processIdentifier
                    != firstProcess.processIdentifier
            )
        }
    }

    @Test
    func workersMemoryMapAppGroupFixture() async throws {
        let fileManager = FileManager.default
        let containerURL = try #require(
            fileManager.containerURL(
                forSecurityApplicationGroupIdentifier:
                    "group.com.tsuyukimakoto.KotodamaVoice"
            )
        )
        let directoryURL = containerURL.appending(
            path: "Diagnostics",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fixtureURL = directoryURL.appending(
            path: "worker-mmap.fixture",
            directoryHint: .notDirectory
        )
        let fixture = Data("KotodamaVoice mmap fixture v1".utf8)
        try fixture.write(to: fixtureURL, options: .atomic)
        defer { try? fileManager.removeItem(at: fixtureURL) }

        let client = WorkerDiagnosticClient()
        for endpoint in WorkerEndpoint.allCases {
            let reply = try await client.mapDiagnosticFixture(in: endpoint)
            #expect(reply.failure == nil)
            #expect(reply.payload == fixture)
        }
    }

    @Test
    func modelFilesAreDeletedAfterEmbeddedWorkersUnload() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appending(
            path: "EmbeddedWorkerModelDeletion-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let suiteName = "com.tsuyukimakoto.EmbeddedWorkerModelDeletion.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? fileManager.removeItem(at: rootURL)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let models = [
            deletionModel(id: "speech-delete-fixture", purpose: .speech),
            deletionModel(id: "formatter-delete-fixture", purpose: .formatter),
        ]
        for model in models {
            let directory = rootURL.appending(
                path: model.id,
                directoryHint: .isDirectory
            )
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data([0]).write(
                to: directory.appending(path: model.fileName)
            )
        }
        let manager = ModelManager(
            models: models,
            rootURL: rootURL,
            defaults: defaults
        )

        for model in models {
            try await manager.deleteInstalledModel(model)
            #expect(manager.states[model.id] == .notInstalled)
            #expect(
                !fileManager.fileExists(
                    atPath: rootURL.appending(path: model.id).path
                )
            )
        }
    }
}

private func deletionModel(
    id: String,
    purpose: ModelPurpose
) -> ModelManifestEntry {
    ModelManifestEntry(
        id: id,
        displayName: id,
        purpose: purpose,
        version: "1",
        sourceURL: URL(string: "https://example.com/\(id).bin")!,
        revision: String(repeating: "a", count: 40),
        fileName: "\(id).bin",
        byteCount: 1,
        sha256: String(repeating: "b", count: 64),
        licenseName: "MIT",
        licenseFile: "MIT-LICENSE.txt",
        licenseURL: URL(string: "https://example.com/license")!,
        runtime: purpose == .speech ? .whisper : .llama
    )
}

private struct DiagnosticProcessFixture: Decodable {
    let processIdentifier: pid_t
}

private func waitUntilProcessTerminates(_ processIdentifier: pid_t) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while kill(processIdentifier, 0) == 0 {
        guard ContinuousClock.now < deadline else {
            throw WorkerTerminationTestError.timedOut
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
private func waitUntilConnectionIsDiscarded(
    by client: WorkerDiagnosticClient,
    endpoint: WorkerEndpoint
) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while client.hasActiveConnection(to: endpoint) {
        guard ContinuousClock.now < deadline else {
            throw WorkerTerminationTestError.timedOut
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private enum WorkerTerminationTestError: Error {
    case timedOut
}
