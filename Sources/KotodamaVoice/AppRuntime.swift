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
    let hotKeySettings: HotKeySettingsStore
    let launchAtLoginSettings: LaunchAtLoginSettings
    let workerDiagnostics: WorkerDiagnostics
    let modelCatalog: ModelCatalog

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
        self.hotKeyBackend = hotKeyBackend
        self.hotKeyController = hotKeyController
        self.hotKeySettings = hotKeySettings
        launchAtLoginSettings = LaunchAtLoginSettings(
            backend: MainAppLaunchAtLoginBackend()
        )
        workerDiagnostics = WorkerDiagnostics()
        modelCatalog = ModelCatalog()

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
        do {
            if pipelineStore.state == .recording {
                _ = try coordinator.stopRecording()
            } else {
                try coordinator.beginRecording()
            }
            operationError = nil
        } catch {
            operationError = "操作を開始できませんでした"
        }
    }
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
