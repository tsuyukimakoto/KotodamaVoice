import CryptoKit
import Foundation
import KotodamaCore
import Network
import Testing
@testable import KotodamaVoice

@Suite(.serialized)
struct ModelDownloadHTTPIntegrationTests {
    @Test @MainActor
    func verifiedHTTPDownloadIsInstalled() async throws {
        let fixture = try DownloadIntegrationFixture()
        defer { fixture.cleanUp() }
        let server = try HTTPModelFixtureServer(payload: fixture.payload)
        let model = fixture.model(sourceURL: server.url)
        let manager = fixture.manager(models: [model])

        manager.install(model)
        let state = try await terminalState(of: model, in: manager)

        #expect(state == .installed)
        #expect(
            try Data(contentsOf: fixture.installedURL(for: model))
                == fixture.payload
        )
        #expect(server.requestCount == 1)
    }

    @Test @MainActor
    func interruptedHTTPDownloadResumesBeforeInstallation() async throws {
        let fixture = try DownloadIntegrationFixture()
        defer { fixture.cleanUp() }
        let server = try HTTPModelFixtureServer(
            payload: fixture.payload,
            interruptsFirstRequest: true
        )
        let model = fixture.model(sourceURL: server.url)
        let manager = fixture.manager(models: [model])
        let installedURL = fixture.installedURL(for: model)

        manager.install(model)
        let interruptedState = try await terminalState(of: model, in: manager)
        guard case .failed = interruptedState else {
            Issue.record("中断した取得が失敗状態になりませんでした")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: installedURL.path))

        manager.install(model)
        let resumedState = try await terminalState(of: model, in: manager)

        #expect(resumedState == .installed)
        #expect(try Data(contentsOf: installedURL) == fixture.payload)
        #expect(server.receivedRangeRequest)
    }

    @Test @MainActor
    func hashMismatchNeverBecomesInstalled() async throws {
        let fixture = try DownloadIntegrationFixture()
        defer { fixture.cleanUp() }
        let server = try HTTPModelFixtureServer(payload: fixture.payload)
        let model = fixture.model(
            sourceURL: server.url,
            sha256: String(repeating: "0", count: 64)
        )
        let manager = fixture.manager(models: [model])
        let installedURL = fixture.installedURL(for: model)

        manager.install(model)
        let state = try await terminalState(of: model, in: manager)
        guard case .failed = state else {
            Issue.record("hash不一致の取得が失敗状態になりませんでした")
            return
        }

        #expect(!FileManager.default.fileExists(atPath: installedURL.path))
    }

    @Test @MainActor
    func insufficientCapacityDoesNotStartHTTPDownload() async throws {
        let fixture = try DownloadIntegrationFixture()
        defer { fixture.cleanUp() }
        let server = try HTTPModelFixtureServer(payload: fixture.payload)
        let model = fixture.model(sourceURL: server.url)
        let storage = CapacityLimitedModelStorage(availableCapacity: 0)
        let coordinator = fixture.coordinator(storage: storage)

        await #expect(throws: ModelInstallError.insufficientDiskSpace) {
            try await coordinator.install(model)
        }

        #expect(server.requestCount == 0)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.installedURL(for: model).path
            )
        )
    }

    @MainActor
    private func terminalState(
        of model: ModelManifestEntry,
        in manager: ModelManager
    ) async throws -> ModelAvailability {
        for _ in 0..<200 {
            let state = manager.states[model.id] ?? .notInstalled
            if case .downloading = state {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            return state
        }
        throw URLError(.timedOut)
    }
}

@MainActor
private final class DownloadIntegrationFixture {
    let payload: Data
    let rootURL: URL
    let defaults: UserDefaults
    private let resumeURL: URL
    private let defaultsSuiteName: String

    init() throws {
        payload = Data((0..<512 * 1_024).map { UInt8($0 % 251) })
        rootURL = FileManager.default.temporaryDirectory.appending(
            path: "ModelDownloadHTTPIntegrationTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defaultsSuiteName = "jp.tsuyuki.ModelDownloadHTTPIntegrationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw URLError(.cannotCreateFile)
        }
        self.defaults = defaults
        resumeURL = rootURL.appending(path: ".resume", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    func model(
        sourceURL: URL,
        sha256: String? = nil
    ) -> ModelManifestEntry {
        ModelManifestEntry(
            id: "http-fixture",
            displayName: "HTTP Fixture",
            purpose: .speech,
            version: "1",
            sourceURL: sourceURL,
            revision: String(repeating: "a", count: 40),
            fileName: "fixture.bin",
            byteCount: Int64(payload.count),
            sha256: sha256 ?? SHA256.hash(data: payload)
                .map { String(format: "%02x", $0) }
                .joined(),
            licenseName: "MIT",
            licenseURL: URL(string: "https://example.com/license")!,
            runtime: .whisper
        )
    }

    func coordinator(
        storage: ModelStorageManaging = FoundationModelStorage()
    ) -> ModelDownloadCoordinator {
        ModelDownloadCoordinator(
            rootURL: rootURL,
            downloader: URLSessionModelDownloader(),
            storage: storage,
            resumeStore: FileModelResumeDataStore(directoryURL: resumeURL)
        )
    }

    func manager(models: [ModelManifestEntry]) -> ModelManager {
        ModelManager(
            models: models,
            rootURL: rootURL,
            defaults: defaults
        )
    }

    func installedURL(for model: ModelManifestEntry) -> URL {
        rootURL
            .appending(path: model.id, directoryHint: .isDirectory)
            .appending(path: model.fileName, directoryHint: .notDirectory)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}

@MainActor
private final class CapacityLimitedModelStorage: ModelStorageManaging {
    private let availableByteCount: Int64
    private let storage = FoundationModelStorage()

    init(availableCapacity: Int64) {
        availableByteCount = availableCapacity
    }

    func availableCapacity(at url: URL) throws -> Int64 {
        availableByteCount
    }

    func prepareDirectories(
        for model: ModelManifestEntry,
        rootURL: URL
    ) throws {
        try storage.prepareDirectories(for: model, rootURL: rootURL)
    }

    func stageDownloadedFile(
        at url: URL,
        for model: ModelManifestEntry,
        rootURL: URL
    ) throws -> URL {
        try storage.stageDownloadedFile(at: url, for: model, rootURL: rootURL)
    }

    func fileSize(at url: URL) throws -> Int64 {
        try storage.fileSize(at: url)
    }

    func sha256(at url: URL) throws -> String {
        try storage.sha256(at: url)
    }

    func installAtomically(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        try storage.installAtomically(from: sourceURL, to: destinationURL)
    }

    func removeItemIfPresent(at url: URL) throws {
        try storage.removeItemIfPresent(at: url)
    }
}

private final class HTTPModelFixtureServer: @unchecked Sendable {
    private let payload: Data
    private let interruptsFirstRequest: Bool
    private let listener: NWListener
    private let queue = DispatchQueue(label: "HTTPModelFixtureServer")
    private let lock = NSLock()
    private var requestHeaders: [String] = []

    var url: URL {
        URL(
            string: "http://127.0.0.1:\(listener.port!.rawValue)/model.bin"
        )!
    }

    init(payload: Data, interruptsFirstRequest: Bool = false) throws {
        self.payload = payload
        self.interruptsFirstRequest = interruptsFirstRequest
        listener = try NWListener(using: .tcp, on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receiveRequest(on: connection, accumulated: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success,
              listener.port != nil else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
    }

    deinit {
        listener.cancel()
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestHeaders.count
    }

    var receivedRangeRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestHeaders.contains { $0.localizedCaseInsensitiveContains("range: bytes=") }
    }

    private func receiveRequest(
        on connection: NWConnection,
        accumulated: Data
    ) {
        connection.start(queue: queue)
        receiveMore(on: connection, accumulated: accumulated)
    }

    private func receiveMore(
        on connection: NWConnection,
        accumulated: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var request = accumulated
            if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(to: connection, request: request)
            } else if !isComplete, error == nil {
                self.receiveMore(on: connection, accumulated: request)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to connection: NWConnection, request: Data) {
        let headers = String(decoding: request, as: UTF8.self)
        lock.lock()
        requestHeaders.append(headers)
        let requestNumber = requestHeaders.count
        lock.unlock()

        let rangeStart = Self.rangeStart(in: headers)
        if interruptsFirstRequest, requestNumber == 1, rangeStart == nil {
            let responseHeaders = Self.responseHeaders(
                status: "200 OK",
                contentLength: payload.count,
                contentRange: nil
            )
            var partialResponse = Data(responseHeaders.utf8)
            partialResponse.append(payload.prefix(64 * 1_024))
            connection.send(content: partialResponse, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let start = min(rangeStart ?? 0, payload.count)
        let body = payload.suffix(from: start)
        let contentRange = rangeStart.map {
            "bytes \($0)-\(payload.count - 1)/\(payload.count)"
        }
        let responseHeaders = Self.responseHeaders(
            status: rangeStart == nil ? "200 OK" : "206 Partial Content",
            contentLength: body.count,
            contentRange: contentRange
        )
        var response = Data(responseHeaders.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func rangeStart(in headers: String) -> Int? {
        for line in headers.components(separatedBy: "\r\n") {
            let lowercased = line.lowercased()
            guard lowercased.hasPrefix("range: bytes=") else { continue }
            let value = lowercased.dropFirst("range: bytes=".count)
            return Int(value.prefix { $0.isNumber })
        }
        return nil
    }

    private static func responseHeaders(
        status: String,
        contentLength: Int,
        contentRange: String?
    ) -> String {
        var lines = [
            "HTTP/1.1 \(status)",
            "Content-Length: \(contentLength)",
            "Content-Type: application/octet-stream",
            "Accept-Ranges: bytes",
            "ETag: \"kotodama-fixture-v1\"",
        ]
        if let contentRange {
            lines.append("Content-Range: \(contentRange)")
        }
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }
}
