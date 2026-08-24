import Foundation
import KotodamaCore
import Observation

enum ModelAvailability: Equatable {
    case notInstalled
    case downloading(Double)
    case installed
    case failed(String)
    case storageUnavailable
}

enum ModelSelectionError: Error, Equatable {
    case notInstalled
    case unknownModel
}

enum ModelDeletionError: Error, Equatable {
    case unknownModel
    case notInstalled
    case storageUnavailable
    case fileSystem
}

@MainActor
protocol ModelInstalling: AnyObject {
    func install(
        _ model: ModelManifestEntry,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL
}

extension ModelDownloadCoordinator: ModelInstalling {}

@Observable
@MainActor
final class ModelManager {
    private(set) var states: [String: ModelAvailability] = [:]
    private(set) var selectedModelIDs: [ModelPurpose: String] = [:]
    private(set) var deletionErrors: [String: String] = [:]

    private var installer: (any ModelInstalling)?
    private var installationCompletions: [String: [(Bool) -> Void]] = [:]
    private var selectAfterInstallationIDs = Set<String>()
    private let modelsByID: [String: ModelManifestEntry]
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let rootURL: URL?
    private let workerUnloader: ModelWorkerUnloading
    private let operationGate: ModelOperationGate

    init(
        models: [ModelManifestEntry],
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        workerUnloader: ModelWorkerUnloading = XPCModelWorkerUnloader(),
        operationGate: ModelOperationGate = ModelOperationGate()
    ) {
        modelsByID = Dictionary(
            uniqueKeysWithValues: models.map { ($0.id, $0) }
        )
        self.defaults = defaults
        self.fileManager = fileManager
        self.workerUnloader = workerUnloader
        self.operationGate = operationGate
        let rootURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: "group.jp.tsuyuki.KotodamaVoice"
        )?.appending(path: "Models", directoryHint: .isDirectory)
        self.rootURL = rootURL
        configure(models: models, rootURL: rootURL, fileManager: fileManager)
    }

    init(
        models: [ModelManifestEntry],
        rootURL: URL,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        workerUnloader: ModelWorkerUnloading = XPCModelWorkerUnloader(),
        operationGate: ModelOperationGate = ModelOperationGate(),
        installer: (any ModelInstalling)? = nil
    ) {
        modelsByID = Dictionary(
            uniqueKeysWithValues: models.map { ($0.id, $0) }
        )
        self.defaults = defaults
        self.fileManager = fileManager
        self.rootURL = rootURL
        self.workerUnloader = workerUnloader
        self.operationGate = operationGate
        configure(
            models: models,
            rootURL: rootURL,
            fileManager: fileManager,
            installer: installer
        )
    }

    func selectedModel(for purpose: ModelPurpose) -> ModelManifestEntry? {
        guard let id = selectedModelIDs[purpose] else { return nil }
        return modelsByID[id]
    }

    func select(_ model: ModelManifestEntry) throws {
        guard modelsByID[model.id] != nil else {
            throw ModelSelectionError.unknownModel
        }
        guard states[model.id] == .installed else {
            throw ModelSelectionError.notInstalled
        }
        selectedModelIDs[model.purpose] = model.id
        defaults.set(model.id, forKey: selectionKey(for: model.purpose))
    }

    func install(
        _ model: ModelManifestEntry,
        selectAfterInstallation: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard modelsByID[model.id] != nil else {
            completion?(false)
            return
        }
        if let completion {
            installationCompletions[model.id, default: []].append(completion)
        }
        if selectAfterInstallation {
            selectAfterInstallationIDs.insert(model.id)
        }
        if states[model.id] == .installed {
            let succeeded = selectIfRequested(model)
            completeInstallation(for: model.id, succeeded: succeeded)
            return
        }
        if case .downloading = states[model.id] {
            return
        }
        guard installer != nil else {
            states[model.id] = .storageUnavailable
            completeInstallation(for: model.id, succeeded: false)
            return
        }
        states[model.id] = .downloading(0)
        Task {
            do {
                try await operationGate.withOperation(for: model.id) {
                    guard self.states[model.id] != .installed else { return }
                    guard let installer = self.installer else {
                        self.states[model.id] = .storageUnavailable
                        return
                    }
                    self.states[model.id] = .downloading(0)
                    _ = try await installer.install(model) { [weak self] progress in
                        self?.states[model.id] = .downloading(progress)
                    }
                    self.states[model.id] = .installed
                    if self.selectAfterInstallationIDs.contains(model.id)
                        || self.selectedModel(for: model.purpose) == nil {
                        try self.select(model)
                    }
                }
                completeInstallation(for: model.id, succeeded: true)
            } catch {
                states[model.id] = .failed(message(for: error))
                completeInstallation(for: model.id, succeeded: false)
            }
        }
    }

    func requestDeletion(
        _ model: ModelManifestEntry,
        completion: ((Bool) -> Void)? = nil
    ) {
        deletionErrors[model.id] = nil
        Task {
            do {
                try await deleteInstalledModel(model)
                completion?(true)
            } catch {
                deletionErrors[model.id] = deletionMessage(for: error)
                completion?(false)
            }
        }
    }

    func deleteInstalledModel(_ model: ModelManifestEntry) async throws {
        try await operationGate.withOperation(for: model.id) {
            guard self.modelsByID[model.id] != nil else {
                throw ModelDeletionError.unknownModel
            }
            guard self.states[model.id] == .installed else {
                throw ModelDeletionError.notInstalled
            }
            guard let rootURL = self.rootURL else {
                throw ModelDeletionError.storageUnavailable
            }

            try await self.workerUnloader.unload(model)

            let modelDirectory = rootURL.appending(
                path: model.id,
                directoryHint: .isDirectory
            )
            do {
                try self.fileManager.removeItem(at: modelDirectory)
            } catch {
                throw ModelDeletionError.fileSystem
            }
            self.states[model.id] = .notInstalled
            self.deletionErrors[model.id] = nil
            if self.selectedModelIDs[model.purpose] == model.id {
                self.selectedModelIDs[model.purpose] = nil
                self.defaults.removeObject(
                    forKey: self.selectionKey(for: model.purpose)
                )
            }
        }
    }

    private func configure(
        models: [ModelManifestEntry],
        rootURL: URL?,
        fileManager: FileManager,
        installer: (any ModelInstalling)? = nil
    ) {
        guard let rootURL else {
            for model in models {
                states[model.id] = .storageUnavailable
            }
            return
        }

        self.installer = installer
            ?? ModelDownloadCoordinator(
                rootURL: rootURL,
                downloader: URLSessionModelDownloader(),
                storage: FoundationModelStorage(fileManager: fileManager),
                resumeStore: FileModelResumeDataStore(
                    directoryURL: rootURL.appending(
                        path: ".resume",
                        directoryHint: .isDirectory
                    ),
                    fileManager: fileManager
                )
            )

        for model in models {
            let installedURL = rootURL
                .appending(path: model.id, directoryHint: .isDirectory)
                .appending(path: model.fileName, directoryHint: .notDirectory)
            states[model.id] = fileManager.fileExists(atPath: installedURL.path)
                ? .installed
                : .notInstalled
        }
        restoreSelections(models: models)
    }

    private func restoreSelections(models: [ModelManifestEntry]) {
        for purpose in [ModelPurpose.speech, .formatter] {
            if let selectedID = defaults.string(
                forKey: selectionKey(for: purpose)
            ), let model = modelsByID[selectedID],
               model.purpose == purpose,
               states[selectedID] == .installed {
                selectedModelIDs[purpose] = selectedID
                continue
            }

            let installed = models.filter {
                $0.purpose == purpose && states[$0.id] == .installed
            }
            let model = installed.first(where: \.isDefault)
                ?? (installed.count == 1 ? installed.first : nil)
            if let model {
                selectedModelIDs[purpose] = model.id
                defaults.set(model.id, forKey: selectionKey(for: purpose))
            } else {
                defaults.removeObject(forKey: selectionKey(for: purpose))
            }
        }
    }

    private func selectionKey(for purpose: ModelPurpose) -> String {
        "selectedModel.\(purpose.rawValue)"
    }

    private func selectIfRequested(_ model: ModelManifestEntry) -> Bool {
        guard selectAfterInstallationIDs.contains(model.id) else { return true }
        do {
            try select(model)
            return true
        } catch {
            return false
        }
    }

    private func completeInstallation(for modelID: String, succeeded: Bool) {
        selectAfterInstallationIDs.remove(modelID)
        let completions = installationCompletions.removeValue(forKey: modelID) ?? []
        for completion in completions {
            completion(succeeded)
        }
    }

    private func message(for error: Error) -> String {
        switch error {
        case ModelInstallError.insufficientDiskSpace:
            "空き容量が不足しています"
        case ModelInstallError.hashMismatch, ModelInstallError.sizeMismatch:
            "取得したモデルの検証に失敗しました"
        case ModelInstallError.interrupted:
            "取得が中断されました。再実行すると続きから取得します"
        case ModelInstallError.operationInProgress:
            "このモデルを処理中です"
        default:
            "モデルを取得できませんでした"
        }
    }

    private func deletionMessage(for error: Error) -> String {
        switch error {
        case is ModelWorkerUnloadError:
            "Workerがモデルを解放できなかったため削除しませんでした"
        case ModelDeletionError.fileSystem:
            "モデルファイルを削除できませんでした"
        default:
            "モデルを削除できませんでした"
        }
    }
}
