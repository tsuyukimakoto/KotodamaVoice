import AVFoundation
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
    private let speechWorker = SpeechWorkerClient()
    private let clipboardOutput = ClipboardOutput()
    private let audioRecording = AudioRecordingService()
    private let temporaryAudioStore = TemporaryAudioStore()
    private var activeAudioLease: TemporaryAudioLease?

    private(set) var operationError: String?
    private let hotKeyBackend: HotKeyRegistering
    private let hotKeyController: GlobalHotKeyController

    init(defaults: UserDefaults = .standard) {
        let pipelineStore = PipelineStore()
        let coordinator = PipelineCoordinator(store: pipelineStore)
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
        modelManager = ModelManager(models: modelCatalog.models)

        audioRecording.onFailure = { [weak self] _ in
            self?.handleAudioRecordingFailure()
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
                    let recording: AVAudioPCMBuffer
                    do {
                        recording = try audioRecording.stop()
                    } catch {
                        audioRecording.cancel()
                        _ = try coordinator.cancel()
                        _ = try coordinator.completeCancellation(requestID: nil)
                        throw error
                    }
                    let requestID = try coordinator.stopRecording()
                    let speechModel: ModelManifestEntry
                    do {
                        guard let selectedModel = modelManager.selectedModel(
                            for: .speech
                        ) else {
                            throw VoiceInputError.speechModelUnavailable
                        }
                        speechModel = selectedModel
                        activeAudioLease?.release()
                        activeAudioLease = try temporaryAudioStore.createLease(
                            requestID: requestID,
                            buffer: recording
                        )
                    } catch {
                        _ = try coordinator.fail(requestID: requestID)
                        throw error
                    }
                    guard let lease = activeAudioLease else {
                        _ = try coordinator.fail(requestID: requestID)
                        throw VoiceInputError.temporaryAudioUnavailable
                    }
                    defer {
                        lease.release()
                        if activeAudioLease === lease {
                            activeAudioLease = nil
                        }
                    }
                    do {
                        let text = try await speechWorker.transcribe(
                            modelID: speechModel.id,
                            audioInput: lease.audioInput,
                            requestID: requestID
                        )
                        _ = try coordinator.completeTranscription(
                            requestID: requestID,
                            requiresFormatting: false
                        )
                        try clipboardOutput.write(text)
                        _ = try coordinator.completeOutput(requestID: requestID)
                    } catch {
                        _ = try? coordinator.fail(requestID: requestID)
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
                            try audioRecording.start()
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

    private func handleAudioRecordingFailure() {
        activeAudioLease?.release()
        activeAudioLease = nil
        do {
            _ = try coordinator.cancel()
            _ = try coordinator.completeCancellation(requestID: nil)
        } catch {
            _ = try? coordinator.fail(requestID: nil)
        }
        operationError = "録音を継続できませんでした"
    }
}

private enum VoiceInputError: Error {
    case speechModelUnavailable
    case temporaryAudioUnavailable
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
