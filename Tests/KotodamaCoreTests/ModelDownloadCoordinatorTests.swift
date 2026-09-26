import Foundation
import Testing
@testable import KotodamaCore

@Test @MainActor
func modelInstallChecksCapacityBeforeDownloading() async {
    let downloader = ModelDownloaderSpy()
    let storage = ModelStorageSpy()
    storage.availableCapacity = 512
    let coordinator = ModelDownloadCoordinator(
        rootURL: URL(fileURLWithPath: "/models"),
        downloader: downloader,
        storage: storage,
        resumeStore: ModelResumeStoreSpy()
    )

    await #expect(throws: ModelInstallError.insufficientDiskSpace) {
        try await coordinator.install(modelEntry(byteCount: 1_024))
    }
    #expect(downloader.downloadCount == 0)
}

@Test @MainActor
func modelInstallMovesOnlyVerifiedDownload() async throws {
    let downloader = ModelDownloaderSpy()
    let storage = ModelStorageSpy()
    storage.availableCapacity = 4_096
    storage.reportedSize = 1_024
    storage.reportedSHA256 = String(repeating: "a", count: 64)
    let coordinator = ModelDownloadCoordinator(
        rootURL: URL(fileURLWithPath: "/models"),
        downloader: downloader,
        storage: storage,
        resumeStore: ModelResumeStoreSpy()
    )
    var progressValues: [Double] = []

    let installedURL = try await coordinator.install(
        modelEntry(byteCount: 1_024),
        progress: { progressValues.append($0) }
    )

    #expect(storage.installedURL == installedURL)
    #expect(storage.installCount == 1)
    #expect(progressValues == [0.5, 1])
}

@Test @MainActor
func foundationModelStorageHashesFileWithoutChangingIt() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "KotodamaVoiceStorageTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "fixture.bin")
    try Data("abc".utf8).write(to: fileURL)
    let storage = FoundationModelStorage()

    #expect(try storage.fileSize(at: fileURL) == 3)
    #expect(
        try storage.sha256(at: fileURL)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
    #expect(try Data(contentsOf: fileURL) == Data("abc".utf8))
}

@Test @MainActor
func modelInstallDeletesStagingFileOnHashMismatch() async {
    let downloader = ModelDownloaderSpy()
    let storage = ModelStorageSpy()
    storage.availableCapacity = 4_096
    storage.reportedSize = 1_024
    storage.reportedSHA256 = String(repeating: "b", count: 64)
    let coordinator = ModelDownloadCoordinator(
        rootURL: URL(fileURLWithPath: "/models"),
        downloader: downloader,
        storage: storage,
        resumeStore: ModelResumeStoreSpy()
    )

    await #expect(throws: ModelInstallError.hashMismatch) {
        try await coordinator.install(modelEntry(byteCount: 1_024))
    }
    #expect(storage.installCount == 0)
    #expect(storage.removedURLs == [storage.stagingURL])
}

@Test @MainActor
func modelInstallUsesSavedResumeDataAfterInterruption() async throws {
    let resumeData = Data("resume".utf8)
    let downloader = ModelDownloaderSpy()
    downloader.outcomes = [
        .failure(ModelDownloadInterrupted(resumeData: resumeData)),
        .success(URL(fileURLWithPath: "/downloaded/model.bin")),
    ]
    let storage = ModelStorageSpy()
    storage.availableCapacity = 4_096
    storage.reportedSize = 1_024
    storage.reportedSHA256 = String(repeating: "a", count: 64)
    let resumeStore = ModelResumeStoreSpy()
    let coordinator = ModelDownloadCoordinator(
        rootURL: URL(fileURLWithPath: "/models"),
        downloader: downloader,
        storage: storage,
        resumeStore: resumeStore
    )
    let model = modelEntry(byteCount: 1_024)

    await #expect(throws: ModelInstallError.interrupted) {
        try await coordinator.install(model)
    }
    _ = try await coordinator.install(model)

    #expect(downloader.receivedResumeData == [nil, resumeData])
    #expect(resumeStore.savedData == nil)
    #expect(storage.installCount == 1)
}

private func modelEntry(byteCount: Int64) -> ModelManifestEntry {
    ModelManifestEntry(
        id: "speech-fixture",
        displayName: "Speech Fixture",
        purpose: .speech,
        version: "1",
        sourceURL: URL(string: "https://www.tsuyukimakoto.com/model.bin")!,
        revision: String(repeating: "0", count: 40),
        fileName: "model.bin",
        byteCount: byteCount,
        sha256: String(repeating: "a", count: 64),
        licenseName: "MIT",
        licenseFile: "MIT-LICENSE.txt",
        licenseURL: URL(string: "https://www.tsuyukimakoto.com/license")!,
        runtime: .whisper
    )
}

@MainActor
private final class ModelDownloaderSpy: ModelDownloading {
    var outcomes: [Result<URL, Error>] = [
        .success(URL(fileURLWithPath: "/downloaded/model.bin")),
    ]
    private(set) var receivedResumeData: [Data?] = []
    var downloadCount: Int { receivedResumeData.count }

    func download(
        from url: URL,
        resumeData: Data?,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        receivedResumeData.append(resumeData)
        progress(0.5)
        return try outcomes.removeFirst().get()
    }
}

@MainActor
private final class ModelStorageSpy: ModelStorageManaging {
    var availableCapacity: Int64 = .max
    var reportedSize: Int64 = 0
    var reportedSHA256 = ""
    let stagingURL = URL(fileURLWithPath: "/models/.downloads/staged")
    private(set) var installedURL: URL?
    private(set) var installCount = 0
    private(set) var removedURLs: [URL] = []

    func availableCapacity(at url: URL) throws -> Int64 { availableCapacity }
    func prepareDirectories(for model: ModelManifestEntry, rootURL: URL) throws {}
    func stageDownloadedFile(
        at url: URL,
        for model: ModelManifestEntry,
        rootURL: URL
    ) throws -> URL { stagingURL }
    func fileSize(at url: URL) throws -> Int64 { reportedSize }
    func sha256(at url: URL) throws -> String { reportedSHA256 }
    func installAtomically(from sourceURL: URL, to destinationURL: URL) throws {
        installCount += 1
        installedURL = destinationURL
    }
    func removeItemIfPresent(at url: URL) throws { removedURLs.append(url) }
}

@MainActor
private final class ModelResumeStoreSpy: ModelResumeDataPersisting {
    var savedData: Data?

    func load(for modelID: String) -> Data? { savedData }
    func save(_ data: Data?, for modelID: String) { savedData = data }
}
