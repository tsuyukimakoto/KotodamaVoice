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
  let formatterSettings: FormatterSettingsStore
  let externalEngineSettings: ExternalEngineSettingsStore
  let outputSettings: OutputSettingsStore
  private let clipboardOutput = ClipboardOutput()
  private let outputHUD = OutputHUDController()
  private let autoInsertTarget = AutoInsertTargetCoordinator()
  private let autoInsertWriter = AutoInsertTextWriter()
  private let localSpeechPipeline: LocalSpeechPipeline
  private let textFormattingPipeline: TextFormattingPipeline

  private(set) var operationError: String?
  private let hotKeyBackend: HotKeyRegistering
  private let hotKeyController: GlobalHotKeyController

  init(defaults: UserDefaults = .standard) {
    let pipelineStore = PipelineStore()
    let coordinator = PipelineCoordinator(store: pipelineStore)
    let audioRecording = AudioRecordingService()
    let modelOperationGate = ModelOperationGate()
    let speechWorkerClient = SpeechWorkerClient(
      operationGate: modelOperationGate
    )
    let localSpeechPipeline = LocalSpeechPipeline(
      store: pipelineStore,
      coordinator: coordinator,
      recorder: audioRecording,
      temporaryAudioStore: TemporaryAudioStore(),
      speech: speechWorkerClient
    )
    let formatterSettings = FormatterSettingsStore(defaults: defaults)
    let externalEngineSettings = ExternalEngineSettingsStore(defaults: defaults)
    let outputSettings: OutputSettingsStore
    #if DEBUG
      if ProcessInfo.processInfo.environment["KOTODAMA_UI_TESTING"] == "1" {
        outputSettings = OutputSettingsStore(
          defaults: defaults,
          permission: UITestAccessibilityPermissionAdapter()
        )
      } else {
        outputSettings = OutputSettingsStore(defaults: defaults)
      }
    #else
      outputSettings = OutputSettingsStore(defaults: defaults)
    #endif
    let formatterWorkerClient = FormatterWorkerClient(
      operationGate: modelOperationGate
    )
    let modelCatalog = ModelCatalog()
    let workerUnloader = XPCModelWorkerUnloader(
      speechClient: speechWorkerClient,
      formatterClient: formatterWorkerClient
    )
    let modelManager: ModelManager
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
          workerUnloader: workerUnloader,
          operationGate: modelOperationGate
        )
      } else {
        modelManager = ModelManager(
          models: modelCatalog.models,
          workerUnloader: workerUnloader,
          operationGate: modelOperationGate
        )
      }
    #else
      modelManager = ModelManager(
        models: modelCatalog.models,
        workerUnloader: workerUnloader,
        operationGate: modelOperationGate
      )
    #endif
    formatterWorkerClient.configure(
      modelID: { [weak modelManager] in
        guard let modelManager,
          let model = modelManager.selectedModel(for: .formatter),
          modelManager.states[model.id] == .installed
        else {
          return nil
        }
        return model.id
      },
      prompt: { [weak formatterSettings] in
        formatterSettings?.activePrompt ?? ""
      }
    )
    let textFormattingPipeline = TextFormattingPipeline(
      coordinator: coordinator,
      settings: formatterSettings,
      builtIn: formatterWorkerClient,
      external: UnavailableTextFormatter()
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
    self.formatterSettings = formatterSettings
    self.externalEngineSettings = externalEngineSettings
    self.outputSettings = outputSettings
    self.textFormattingPipeline = textFormattingPipeline
    self.modelCatalog = modelCatalog
    self.modelManager = modelManager
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
        var completionMessage: String?
        if pipelineStore.state == .recording {
          guard
            let speechModel = modelManager.selectedModel(
              for: .speech
            )
          else {
            localSpeechPipeline.cancelRecording()
            throw VoiceInputError.speechModelUnavailable
          }
          let transcription =
            try await localSpeechPipeline
            .stopAndTranscribe(
              modelID: speechModel.id
            )
          let output = try await textFormattingPipeline.process(
            transcription
          )
          do {
            let outputOutcome = try await deliverOutput(
              output.text,
              usedFormattingFallback: output.usedFallback
            )
            _ = try coordinator.completeOutput(
              requestID: transcription.requestID
            )
            if output.usedFallback {
              completionMessage = "文章整形を適用できなかったため原文を出力しました"
            }
            if let hudNotification = outputOutcome.hudNotification {
              outputHUD.show(hudNotification)
            }
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
          if outputSettings.mode == .autoInsert {
            do {
              try autoInsertTarget.captureForRecording()
            } catch {
              autoInsertTarget.clear()
            }
          } else {
            autoInsertTarget.clear()
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
        operationError = completionMessage
      } catch RecordingStartError.microphonePermissionDenied {
        autoInsertTarget.clear()
        operationError = "マイクの使用が許可されていません"
      } catch VoiceInputError.speechModelUnavailable {
        autoInsertTarget.clear()
        operationError = "使用するSpeechモデルが見つかりません"
      } catch is SpeechWorkerClientError {
        autoInsertTarget.clear()
        operationError = "文字起こしに失敗しました"
      } catch is ClipboardOutputError {
        autoInsertTarget.clear()
        operationError = "クリップボードへ結果を書き込めませんでした"
        outputHUD.show(.clipboardFailed)
      } catch {
        autoInsertTarget.clear()
        operationError = "操作を開始できませんでした"
      }
    }
  }

  private func deliverOutput(
    _ text: String,
    usedFormattingFallback: Bool
  ) async throws -> OutputDeliveryOutcome {
    defer { autoInsertTarget.clear() }
    guard outputSettings.mode == .autoInsert else {
      try clipboardOutput.write(text)
      return usedFormattingFallback
        ? .clipboardSucceededWithFormattingFallback
        : .clipboardSucceeded
    }

    do {
      let target = try autoInsertTarget.revalidateForOutput()
      try await autoInsertWriter.replaceSelection(with: text, in: target)
      return .automaticInsertionSucceeded
    } catch {
      try clipboardOutput.write(text)
      return .automaticInsertionFellBackToClipboard
    }
  }

  private func handleAudioRecordingFailure(_ error: Error) {
    autoInsertTarget.clear()
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
