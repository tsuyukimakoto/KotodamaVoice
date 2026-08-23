import CryptoKit
import Foundation

public struct ModelDownloadInterrupted: Error, Equatable, Sendable {
    public let resumeData: Data?

    public init(resumeData: Data?) {
        self.resumeData = resumeData
    }
}

public enum ModelInstallError: Error, Equatable, Sendable {
    case insufficientDiskSpace
    case operationInProgress
    case interrupted
    case downloadFailed
    case sizeMismatch
    case hashMismatch
    case fileSystem
}

@MainActor
public protocol ModelDownloading: AnyObject {
    func download(
        from url: URL,
        resumeData: Data?,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL
}

@MainActor
public protocol ModelStorageManaging: AnyObject {
    func availableCapacity(at url: URL) throws -> Int64
    func prepareDirectories(
        for model: ModelManifestEntry,
        rootURL: URL
    ) throws
    func stageDownloadedFile(
        at url: URL,
        for model: ModelManifestEntry,
        rootURL: URL
    ) throws -> URL
    func fileSize(at url: URL) throws -> Int64
    func sha256(at url: URL) throws -> String
    func installAtomically(from sourceURL: URL, to destinationURL: URL) throws
    func removeItemIfPresent(at url: URL) throws
}

@MainActor
public protocol ModelResumeDataPersisting: AnyObject {
    func load(for modelID: String) throws -> Data?
    func save(_ data: Data?, for modelID: String) throws
}

@MainActor
public final class ModelDownloadCoordinator {
    private let rootURL: URL
    private let downloader: ModelDownloading
    private let storage: ModelStorageManaging
    private let resumeStore: ModelResumeDataPersisting
    private var activeModelIDs = Set<String>()

    public init(
        rootURL: URL,
        downloader: ModelDownloading,
        storage: ModelStorageManaging,
        resumeStore: ModelResumeDataPersisting
    ) {
        self.rootURL = rootURL
        self.downloader = downloader
        self.storage = storage
        self.resumeStore = resumeStore
    }

    public func install(
        _ model: ModelManifestEntry,
        progress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard activeModelIDs.insert(model.id).inserted else {
            throw ModelInstallError.operationInProgress
        }
        defer { activeModelIDs.remove(model.id) }

        do {
            let capacity = try storage.availableCapacity(at: rootURL)
            guard capacity >= model.byteCount else {
                throw ModelInstallError.insufficientDiskSpace
            }
            try storage.prepareDirectories(for: model, rootURL: rootURL)
        } catch let error as ModelInstallError {
            throw error
        } catch {
            throw ModelInstallError.fileSystem
        }

        let resumeData: Data?
        do {
            resumeData = try resumeStore.load(for: model.id)
        } catch {
            throw ModelInstallError.fileSystem
        }

        let downloadedURL: URL
        do {
            downloadedURL = try await downloader.download(
                from: model.sourceURL,
                resumeData: resumeData,
                progress: progress
            )
            try resumeStore.save(nil, for: model.id)
        } catch let interruption as ModelDownloadInterrupted {
            do {
                try resumeStore.save(interruption.resumeData, for: model.id)
            } catch {
                throw ModelInstallError.fileSystem
            }
            throw ModelInstallError.interrupted
        } catch {
            throw ModelInstallError.downloadFailed
        }

        let stagingURL: URL
        do {
            stagingURL = try storage.stageDownloadedFile(
                at: downloadedURL,
                for: model,
                rootURL: rootURL
            )
        } catch {
            try? storage.removeItemIfPresent(at: downloadedURL)
            throw ModelInstallError.fileSystem
        }

        do {
            guard try storage.fileSize(at: stagingURL) == model.byteCount else {
                try storage.removeItemIfPresent(at: stagingURL)
                throw ModelInstallError.sizeMismatch
            }
            guard try storage.sha256(at: stagingURL) == model.sha256 else {
                try storage.removeItemIfPresent(at: stagingURL)
                throw ModelInstallError.hashMismatch
            }

            let destinationURL = rootURL
                .appending(path: model.id, directoryHint: .isDirectory)
                .appending(path: model.fileName, directoryHint: .notDirectory)
            try storage.installAtomically(
                from: stagingURL,
                to: destinationURL
            )
            progress(1)
            return destinationURL
        } catch let error as ModelInstallError {
            throw error
        } catch {
            try? storage.removeItemIfPresent(at: stagingURL)
            throw ModelInstallError.fileSystem
        }
    }
}

@MainActor
public final class FoundationModelStorage: ModelStorageManaging {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func availableCapacity(at url: URL) throws -> Int64 {
        let values = try url.deletingLastPathComponent().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    public func prepareDirectories(
        for model: ModelManifestEntry,
        rootURL: URL
    ) throws {
        try fileManager.createDirectory(
            at: rootURL.appending(path: ".downloads", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: rootURL.appending(path: model.id, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    public func stageDownloadedFile(
        at url: URL,
        for model: ModelManifestEntry,
        rootURL: URL
    ) throws -> URL {
        let stagingURL = rootURL
            .appending(path: ".downloads", directoryHint: .isDirectory)
            .appending(
                path: "\(model.id)-\(UUID().uuidString).download",
                directoryHint: .notDirectory
            )
        try fileManager.moveItem(at: url, to: stagingURL)
        return stagingURL
    }

    public func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else {
            throw ModelInstallError.fileSystem
        }
        return Int64(fileSize)
    }

    public func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func installAtomically(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: sourceURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    public func removeItemIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}

@MainActor
public final class FileModelResumeDataStore: ModelResumeDataPersisting {
    private let directoryURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    public func load(for modelID: String) throws -> Data? {
        let url = fileURL(for: modelID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func save(_ data: Data?, for modelID: String) throws {
        let url = fileURL(for: modelID)
        if let data {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func fileURL(for modelID: String) -> URL {
        directoryURL.appending(
            path: "\(modelID).resume",
            directoryHint: .notDirectory
        )
    }
}
