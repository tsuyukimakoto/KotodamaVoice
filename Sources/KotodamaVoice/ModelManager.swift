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

@Observable
@MainActor
final class ModelManager {
    private(set) var states: [String: ModelAvailability] = [:]
    private(set) var selectedModelIDs: [ModelPurpose: String] = [:]

    private var coordinator: ModelDownloadCoordinator?
    private let modelsByID: [String: ModelManifestEntry]
    private let defaults: UserDefaults

    init(
        models: [ModelManifestEntry],
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        modelsByID = Dictionary(
            uniqueKeysWithValues: models.map { ($0.id, $0) }
        )
        self.defaults = defaults
        let rootURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: "group.jp.tsuyuki.KotodamaVoice"
        )?.appending(path: "Models", directoryHint: .isDirectory)
        configure(models: models, rootURL: rootURL, fileManager: fileManager)
    }

    init(
        models: [ModelManifestEntry],
        rootURL: URL,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        modelsByID = Dictionary(
            uniqueKeysWithValues: models.map { ($0.id, $0) }
        )
        self.defaults = defaults
        configure(models: models, rootURL: rootURL, fileManager: fileManager)
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

    func install(_ model: ModelManifestEntry) {
        guard let coordinator else {
            states[model.id] = .storageUnavailable
            return
        }
        states[model.id] = .downloading(0)
        Task {
            do {
                _ = try await coordinator.install(model) { [weak self] progress in
                    self?.states[model.id] = .downloading(progress)
                }
                states[model.id] = .installed
                if selectedModel(for: model.purpose) == nil {
                    try select(model)
                }
            } catch {
                states[model.id] = .failed(message(for: error))
            }
        }
    }

    private func configure(
        models: [ModelManifestEntry],
        rootURL: URL?,
        fileManager: FileManager
    ) {
        guard let rootURL else {
            for model in models {
                states[model.id] = .storageUnavailable
            }
            return
        }

        coordinator = ModelDownloadCoordinator(
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
            if installed.count == 1, let model = installed.first {
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
}
