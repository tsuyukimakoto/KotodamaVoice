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
  let speechSettings: SpeechSettingsStore
  let formatterSettings: FormatterSettingsStore
  let formatterEngineSelection: FormatterEngineSelectionCoordinator
  let externalEngineSettings: ExternalEngineSettingsStore
  let outputSettings: OutputSettingsStore
  let debugLogSettings: DebugLogSettingsStore
  let glossarySession: GlossarySession
  private(set) var modelNavigationTargetID: String?
  private var outputSelectionWindow: OutputSelectionWindowPresenter?
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
    let speechSettings = SpeechSettingsStore(defaults: defaults)
    let externalEngineSettings = ExternalEngineSettingsStore(defaults: defaults)
    let glossarySettings: GlossarySettingsStore
    let glossaryDiagnostics: GlossaryDiagnostics
    #if DEBUG
      if ProcessInfo.processInfo.environment["KOTODAMA_UI_TESTING"] == "1" {
        let directory =
          ProcessInfo.processInfo.environment["KOTODAMA_UI_TEST_GLOSSARY_DIRECTORY"]
          .map { URL(fileURLWithPath: $0) }
          ?? URL(
            fileURLWithPath:
              "/private/tmp/KotodamaGlossaryUI-\(ProcessInfo.processInfo.processIdentifier)")
        glossarySettings = GlossarySettingsStore(directory: directory, defaults: defaults)
        glossaryDiagnostics = GlossaryDiagnostics(directory: directory.appending(path: "logs"))
      } else {
        glossarySettings = GlossarySettingsStore(defaults: defaults)
        glossaryDiagnostics = GlossaryDiagnostics()
      }
    #else
      glossarySettings = GlossarySettingsStore(defaults: defaults)
      glossaryDiagnostics = GlossaryDiagnostics()
    #endif
    let glossarySession = GlossarySession(
      settings: glossarySettings, diagnostics: glossaryDiagnostics)
    #if DEBUG
      if ProcessInfo.processInfo.environment["KOTODAMA_UI_TESTING"] == "1",
        ProcessInfo.processInfo.environment["KOTODAMA_UI_TEST_GLOSSARY_OMITTED"] == "1"
      {
        glossarySession.begin()
        glossarySession.record(
          requestID: PipelineRequestID(), stage: .speech, status: .success,
          text: "", effective: .applied, engine: "ui_fixture")
        glossarySession.finish()
      }
    #endif
    let selectedSpeech = SelectedSpeechTranscriber(
      settings: speechSettings,
      builtIn: speechWorkerClient,
      external: ConfiguredExternalSpeechTranscriber(
        settings: externalEngineSettings
      )
    )
    let localSpeechPipeline = LocalSpeechPipeline(
      store: pipelineStore,
      coordinator: coordinator,
      recorder: audioRecording,
      temporaryAudioStore: TemporaryAudioStore(),
      speech: selectedSpeech,
      glossary: glossarySession
    )
    let formatterSettings = FormatterSettingsStore(defaults: defaults)
    let debugLogSettings: DebugLogSettingsStore
    #if DEBUG
      if let testLogPath = ProcessInfo.processInfo.environment[
        "KOTODAMA_UI_TEST_LOG_DIRECTORY"
      ] {
        debugLogSettings = DebugLogSettingsStore(
          defaults: defaults,
          logsDirectoryURL: URL(filePath: testLogPath, directoryHint: .isDirectory)
        )
      } else {
        debugLogSettings = DebugLogSettingsStore(defaults: defaults)
      }
    #else
      debugLogSettings = DebugLogSettingsStore(defaults: defaults)
    #endif
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
        let installResult = ProcessInfo.processInfo.environment[
          "KOTODAMA_UI_TEST_MODEL_INSTALL_RESULT"
        ]
        let testInstaller = installResult.map {
          UITestModelInstaller(
            rootURL: testRootURL,
            succeeds: $0 == "success"
          )
        }
        modelManager = ModelManager(
          models: modelCatalog.models,
          rootURL: testRootURL,
          defaults: defaults,
          workerUnloader: testInstaller == nil
            ? workerUnloader
            : UITestModelWorkerUnloader(),
          operationGate: modelOperationGate,
          installer: testInstaller
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
    let formatterEngineSelection = FormatterEngineSelectionCoordinator(
      settings: formatterSettings,
      models: modelCatalog.models,
      isInstalledAndSelected: { [weak modelManager] model in
        guard let modelManager else { return false }
        return modelManager.states[model.id] == .installed
          && modelManager.selectedModel(for: .formatter)?.id == model.id
      }
    )
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
      external: ConfiguredExternalTextFormatter(
        settings: externalEngineSettings,
        prompt: { [weak formatterSettings] in
          formatterSettings?.activePrompt ?? ""
        }
      ),
      glossary: glossarySession,
      permitsExternalGlossary: {
        guard let configuration = externalEngineSettings.configuration(for: .formatter) else {
          return false
        }
        return glossarySettings.permits(configuration.endpointURL)
      },
      modelIdentifier: { engine in
        engine == .builtIn
          ? modelManager.selectedModel(for: .formatter)?.id
          : externalEngineSettings.configuration(for: .formatter)?.model
      }
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
    self.speechSettings = speechSettings
    self.formatterSettings = formatterSettings
    self.formatterEngineSelection = formatterEngineSelection
    self.externalEngineSettings = externalEngineSettings
    self.outputSettings = outputSettings
    self.debugLogSettings = debugLogSettings
    self.glossarySession = glossarySession
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
      debugLogSettings.record(
        DebugErrorEvent(
          area: .hotKey,
          stage: .hotKeyRegistration,
          error: (error as? HotKeyRegistrationError) == .conflict
            ? .hotKeyConflict
            : .systemFailure
        )
      )
      operationError = "グローバルショートカットを登録できませんでした"
    }

    if outputSettings.mode == nil {
      Task { @MainActor [weak self] in
        self?.showOutputSelection()
      }
    }
  }

  func toggleRecording() {
    if pipelineStore.state != .recording, outputSettings.mode == nil {
      operationError = "録音を始める前に出力方式を選択してください"
      showOutputSelection()
      return
    }

    Task {
      do {
        var completionMessage: String?
        if pipelineStore.state == .recording {
          guard let speechModelID = selectedSpeechModelID() else {
            localSpeechPipeline.cancelRecording()
            throw VoiceInputError.speechModelUnavailable
          }
          let transcription =
            try await localSpeechPipeline
            .stopAndTranscribe(
              modelID: speechModelID
            )
          let output = try await textFormattingPipeline.process(
            transcription
          )
          do {
            let outputOutcome = try await deliverOutput(
              output.text,
              usedFormattingFallback: output.usedFallback,
              requestID: transcription.requestID.rawValue
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
          guard selectedSpeechModelID() != nil else {
            debugLogSettings.record(
              DebugErrorEvent(
                area: .speech,
                stage: .recordingStart,
                error: .speechModelUnavailable
              )
            )
            operationError =
              speechSettings.engine == .builtIn
              ? "使用するSpeechモデルをモデル画面で取得・選択してください"
              : "外部Speech Engineを設定してください"
            return
          }
          if outputSettings.mode == .autoInsert {
            do {
              try autoInsertTarget.captureForRecording()
            } catch {
              debugLogSettings.record(
                autoInsertDebugEvent(for: error, defaultStage: .targetCapture)
              )
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
        debugLogSettings.record(
          DebugErrorEvent(
            area: .audio,
            stage: .recordingStart,
            error: .microphonePermissionDenied
          )
        )
        autoInsertTarget.clear()
        operationError = "マイクの使用が許可されていません"
      } catch VoiceInputError.speechModelUnavailable {
        debugLogSettings.record(
          DebugErrorEvent(
            area: .speech,
            stage: .transcription,
            error: .speechModelUnavailable
          )
        )
        autoInsertTarget.clear()
        operationError = "使用するSpeechモデルが見つかりません"
      } catch let error where isSpeechTranscriptionFailure(error) {
        debugLogSettings.record(
          DebugErrorEvent(
            area: .speech,
            stage: .transcription,
            error: .speechTranscriptionFailed
          )
        )
        autoInsertTarget.clear()
        operationError = "文字起こしに失敗しました"
      } catch is ClipboardOutputError {
        debugLogSettings.record(
          DebugErrorEvent(
            area: .output,
            stage: .delivery,
            error: .clipboardWriteFailed
          )
        )
        autoInsertTarget.clear()
        operationError = "クリップボードへ結果を書き込めませんでした"
        outputHUD.show(.clipboardFailed)
      } catch {
        autoInsertTarget.clear()
        operationError = "操作を開始できませんでした"
      }
    }
  }

  func showOutputSelection() {
    if outputSelectionWindow == nil {
      outputSelectionWindow = OutputSelectionWindowPresenter(
        settings: outputSettings
      )
    }
    outputSelectionWindow?.show()
  }

  func beginPendingFormatterModelAcquisition() {
    guard
      let model =
        formatterEngineSelection
        .beginPendingModelAcquisition()
    else { return }
    modelNavigationTargetID = model.id
    modelManager.install(
      model,
      selectAfterInstallation: true
    ) { [weak formatterEngineSelection] succeeded in
      formatterEngineSelection?.modelAcquisitionDidFinish(
        model,
        succeeded: succeeded
      )
    }
  }

  func requestModelDeletion(_ model: ModelManifestEntry) {
    modelManager.requestDeletion(model) { [weak formatterEngineSelection] succeeded in
      guard succeeded else { return }
      formatterEngineSelection?.modelWasDeleted(model)
    }
  }

  private func selectedSpeechModelID() -> String? {
    switch speechSettings.engine {
    case .builtIn:
      guard let model = modelManager.selectedModel(for: .speech),
        modelManager.states[model.id] == .installed
      else {
        return nil
      }
      return model.id
    case .external:
      return externalEngineSettings.configuration(for: .speech) == nil
        ? nil
        : ""
    }
  }

  private func isSpeechTranscriptionFailure(_ error: Error) -> Bool {
    error is SpeechWorkerClientError
      || error is ExternalSpeechAdapterError
      || error is ExternalSpeechInputError
      || error is ExternalEndpointPolicyError
      || error is ExternalEngineRuntimeError
      || error is URLError
  }

  private func deliverOutput(
    _ text: String,
    usedFormattingFallback: Bool,
    requestID: UUID?
  ) async throws -> OutputDeliveryOutcome {
    let delivery = OutputDeliveryCoordinator(
      clipboard: clipboardOutput,
      autoInsertTarget: autoInsertTarget,
      autoInsertWriter: autoInsertWriter,
      debugLogger: debugLogSettings
    )
    guard let mode = outputSettings.mode else {
      throw VoiceInputError.outputModeUnavailable
    }
    return try await delivery.deliver(
      text,
      mode: mode,
      usedFormattingFallback: usedFormattingFallback,
      requestID: requestID
    )
  }

  private func handleAudioRecordingFailure(_ error: Error) {
    debugLogSettings.record(
      DebugErrorEvent(
        area: .audio,
        stage: .recording,
        error: (error as? AudioRecordingError) == .unavailableInput
          ? .inputDeviceUnavailable
          : .systemFailure
      )
    )
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

#if DEBUG
  @MainActor
  private final class UITestModelInstaller: ModelInstalling {
    private let rootURL: URL
    private let succeeds: Bool

    init(rootURL: URL, succeeds: Bool) {
      self.rootURL = rootURL
      self.succeeds = succeeds
    }

    func install(
      _ model: ModelManifestEntry,
      progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
      progress(0.5)
      await Task.yield()
      guard succeeds else { throw ModelInstallError.downloadFailed }
      let directory = rootURL.appending(
        path: model.id,
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let fileURL = directory.appending(
        path: model.fileName,
        directoryHint: .notDirectory
      )
      try Data().write(to: fileURL)
      progress(1)
      return fileURL
    }
  }

  @MainActor
  private final class UITestModelWorkerUnloader: ModelWorkerUnloading {
    func unload(_ model: ModelManifestEntry) async throws {}
  }
#endif

@MainActor
final class OutputDeliveryCoordinator {
  private let clipboard: ClipboardWriting
  private let autoInsertTarget: AutoInsertTargetCoordinating
  private let autoInsertWriter: AutoInsertWriting
  private let debugLogger: DebugErrorLogging?

  init(
    clipboard: ClipboardWriting,
    autoInsertTarget: AutoInsertTargetCoordinating,
    autoInsertWriter: AutoInsertWriting,
    debugLogger: DebugErrorLogging? = nil
  ) {
    self.clipboard = clipboard
    self.autoInsertTarget = autoInsertTarget
    self.autoInsertWriter = autoInsertWriter
    self.debugLogger = debugLogger
  }

  func deliver(
    _ text: String,
    mode: OutputMode,
    usedFormattingFallback: Bool,
    requestID: UUID? = nil
  ) async throws -> OutputDeliveryOutcome {
    defer { autoInsertTarget.clear() }
    guard mode == .autoInsert else {
      try clipboard.write(text)
      return usedFormattingFallback
        ? .clipboardSucceededWithFormattingFallback
        : .clipboardSucceeded
    }

    do {
      let target = try autoInsertTarget.revalidateForOutput()
      try await autoInsertWriter.replaceSelection(with: text, in: target)
      return .automaticInsertionSucceeded
    } catch {
      debugLogger?.record(
        autoInsertDebugEvent(
          for: error,
          defaultStage: .delivery,
          requestID: requestID
        )
      )
      try clipboard.write(text)
      return .automaticInsertionFellBackToClipboard
    }
  }
}

private enum VoiceInputError: Error {
  case speechModelUnavailable
  case outputModeUnavailable
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
