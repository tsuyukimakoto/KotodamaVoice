import Carbon.HIToolbox
import Foundation
import KotodamaCore
import Observation

@Observable
@MainActor
final class AppRuntime {
    static let defaultHotKey = HotKeyDescriptor(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey)
    )

    let pipelineStore: PipelineStore
    let coordinator: PipelineCoordinator
    let recordingStartCoordinator: RecordingStartCoordinator
    let hotKeySettings: HotKeySettingsStore
    let launchAtLoginSettings: LaunchAtLoginSettings
    let workerDiagnostics: WorkerDiagnostics
    let modelCatalog: ModelCatalog
    let modelManager: ModelManager
    private let clipboardOutput = ClipboardOutput()
    private let localSpeechPipeline: LocalSpeechPipeline

    private(set) var operationError: String?
    private let hotKeyBackend: HotKeyRegistering
    private let hotKeyController: GlobalHotKeyController

    init(defaults: UserDefaults = .standard) {
        let pipelineStore = PipelineStore()
        let coordinator = PipelineCoordinator(store: pipelineStore)
        let audioRecording = AudioRecordingService()
        let speechWorkerClient = SpeechWorkerClient()
        let localSpeechPipeline = LocalSpeechPipeline(
            store: pipelineStore,
            coordinator: coordinator,
            recorder: audioRecording,
            temporaryAudioStore: TemporaryAudioStore(),
            speech: speechWorkerClient
        )
        let hotKeyBackend: HotKeyRegistering

        do {
            hotKeyBackend = try CarbonHotKeyBackend()
        } catch let error as HotKeyRegistrationError {
            hotKeyBackend = UnavailableHotKeyBackend(error: error)
        } catch {
            hotKeyBackend = UnavailableHotKeyBackend(error: .systemError(-1))
        }

        let hotKeyController = GlobalHotKeyController(backend: hotKeyBackend)
        let hotKeySettings = HotKeySettingsStore(
            controller: hotKeyController,
            persistence: UserDefaultsHotKeyPreference(defaults: defaults),
            defaultDescriptor: Self.defaultHotKey
        )

        self.pipelineStore = pipelineStore
        self.coordinator = coordinator
        self.localSpeechPipeline = localSpeechPipeline
        recordingStartCoordinator = RecordingStartCoordinator(
            pipeline: coordinator,
            store: pipelineStore,
            permission: AVMicrophonePermission()
        )
        self.hotKeyBackend = hotKeyBackend
        self.hotKeyController = hotKeyController
        self.hotKeySettings = hotKeySettings
        launchAtLoginSettings = LaunchAtLoginSettings(
            backend: MainAppLaunchAtLoginBackend()
        )
        workerDiagnostics = WorkerDiagnostics()
        let modelCatalog = ModelCatalog()
        self.modelCatalog = modelCatalog
#if DEBUG
        if ProcessInfo.processInfo.environment["KOTODAMA_UI_TESTING"] == "1" {
            let testRootURL = FileManager.default.temporaryDirectory.appending(
                path: "KotodamaVoiceUITests-\(ProcessInfo.processInfo.processIdentifier)",
                directoryHint: .isDirectory
            )
            modelManager = ModelManager(
                models: modelCatalog.models,
                rootURL: testRootURL,
                defaults: defaults,
                workerUnloader: XPCModelWorkerUnloader(
                    speechClient: speechWorkerClient
                )
            )
        } else {
            modelManager = ModelManager(
                models: modelCatalog.models,
                workerUnloader: XPCModelWorkerUnloader(
                    speechClient: speechWorkerClient
                )
            )
        }
#else
        modelManager = ModelManager(
            models: modelCatalog.models,
            workerUnloader: XPCModelWorkerUnloader(
                speechClient: speechWorkerClient
            )
        )
#endif

        audioRecording.onFailure = { [weak self] error in
            self?.handleAudioRecordingFailure(error)
        }

        hotKeyController.onPress = { [weak self] in
            self?.toggleRecording()
        }

        do {
            try hotKeySettings.activate()
        } catch {
            operationError = "グローバルショートカットを登録できませんでした"
        }
    }

    func toggleRecording() {
        Task {
            do {
                if pipelineStore.state == .recording {
                    guard let speechModel = modelManager.selectedModel(
                        for: .speech
                    ) else {
                        localSpeechPipeline.cancelRecording()
                        throw VoiceInputError.speechModelUnavailable
                    }
                    let transcription = try await localSpeechPipeline
                        .stopAndTranscribe(
                            modelID: speechModel.id
                        )
                    do {
                        _ = try coordinator.completeTranscription(
                            requestID: transcription.requestID,
                            requiresFormatting: false
                        )
                        try clipboardOutput.write(transcription.text)
                        _ = try coordinator.completeOutput(
                            requestID: transcription.requestID
                        )
                    } catch {
                        _ = try? coordinator.fail(
                            requestID: transcription.requestID
                        )
                        throw error
                    }
                } else {
                    if case .failed = pipelineStore.state {
                        _ = try coordinator.recover()
                    }
                    guard let speechModel = modelManager.selectedModel(for: .speech),
                          modelManager.states[speechModel.id] == .installed
                    else {
                        operationError = "使用するSpeechモデルをモデル画面で取得・選択してください"
                        return
                    }
                    let result = try await recordingStartCoordinator.beginRecording()
                    if result == .applied {
                        do {
                            try localSpeechPipeline.startRecording()
                        } catch {
                            _ = try coordinator.fail(requestID: nil)
                            throw error
                        }
                    }
                }
                operationError = nil
            } catch RecordingStartError.microphonePermissionDenied {
                operationError = "マイクの使用が許可されていません"
            } catch VoiceInputError.speechModelUnavailable {
                operationError = "使用するSpeechモデルが見つかりません"
            } catch is SpeechWorkerClientError {
                operationError = "文字起こしに失敗しました"
            } catch is ClipboardOutputError {
                operationError = "クリップボードへ結果を書き込めませんでした"
            } catch {
                operationError = "操作を開始できませんでした"
            }
        }
    }

    private func handleAudioRecordingFailure(_ error: Error) {
        localSpeechPipeline.recordingDidFail(error)
        switch error as? AudioRecordingError {
        case .inputConfigurationChanged, .unavailableInput:
            operationError = "入力機器が利用できなくなったため録音を中止しました"
        case .maximumDurationExceeded:
            operationError = "録音時間が上限に達したため録音を中止しました"
        default:
            operationError = "録音を継続できませんでした"
        }
    }
}

private enum VoiceInputError: Error {
    case speechModelUnavailable
}

@MainActor
private final class UnavailableHotKeyBackend: HotKeyRegistering {
    var eventHandler: ((HotKeyRegistrationToken, HotKeyEvent) -> Void)?

    private let error: HotKeyRegistrationError

    init(error: HotKeyRegistrationError) {
        self.error = error
    }

    func register(
        _ descriptor: HotKeyDescriptor
    ) throws -> HotKeyRegistrationToken {
        throw error
    }

    func unregister(_ token: HotKeyRegistrationToken) {}
}
