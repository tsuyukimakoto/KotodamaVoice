import AppKit
import Foundation
import KotodamaCore
import Security
import Testing
@testable import KotodamaVoice

@Test func applicationModuleLoads() {
    #expect(true)
}

@Test @MainActor
func bundledMenuBarIconLoadsAsATemplateImage() throws {
    let image = try #require(NSImage(named: "MenuBarIcon"))

    #expect(image.isTemplate)
}

@Test
func bundledApplicationIconIsConfigured() {
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon")
    #expect(Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil)
}

@Test func signedHostAllowsMicrophoneInput() throws {
    let task = try #require(SecTaskCreateFromSelf(nil))
    let entitlement = SecTaskCopyValueForEntitlement(
        task,
        "com.apple.security.device.audio-input" as CFString,
        nil
    ) as? Bool

    #expect(entitlement == true)
}

@Test @MainActor
func hotKeyPreferenceRoundTripsDescriptor() throws {
    let suiteName = "com.tsuyukimakoto.KotodamaVoiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preference = UserDefaultsHotKeyPreference(defaults: defaults)
    let descriptor = HotKeyDescriptor(keyCode: 49, modifiers: 6_144)

    #expect(preference.load() == nil)
    preference.save(descriptor)
    #expect(preference.load() == descriptor)
}

@Test @MainActor
func bundledModelCatalogContainsPinnedCandidates() throws {
    let catalog = ModelCatalog()

    #expect(catalog.loadError == nil)
    #expect(catalog.models.map(\.id) == [
        "whisper-large-v3-turbo-f16",
        "whisper-large-v3-turbo-q5-0",
        "gemma-4-e4b-it-qat-q4-0",
    ])
    let defaultSpeech = try #require(
        catalog.models.first(where: { $0.isDefault })
    )
    #expect(defaultSpeech.id == "whisper-large-v3-turbo-q5-0")
    #expect(defaultSpeech.revision == "5359861c739e955e79d9a303bcbc70fb988958b1")
    #expect(defaultSpeech.byteCount == 574_041_195)
    #expect(
        defaultSpeech.sha256
            == "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    )
    #expect(defaultSpeech.licenseName == "MIT")
    #expect(defaultSpeech.licenseURL.absoluteString == "https://github.com/openai/whisper/blob/main/LICENSE")
}

@Test @MainActor
func launchAtLoginTracksRegistrationAndUnregistration() {
    let backend = LaunchAtLoginBackendSpy()
    let settings = LaunchAtLoginSettings(backend: backend)

    #expect(!settings.isEnabled)
    settings.setEnabled(true)
    #expect(settings.isEnabled)
    #expect(backend.registerCount == 1)

    settings.setEnabled(false)
    #expect(!settings.isEnabled)
    #expect(backend.unregisterCount == 1)
    #expect(settings.errorMessage == nil)
}

@Test @MainActor
func launchAtLoginReflectsBackendStateAfterFailure() {
    let backend = LaunchAtLoginBackendSpy()
    backend.registrationError = TestLaunchAtLoginError.failed
    let settings = LaunchAtLoginSettings(backend: backend)

    settings.setEnabled(true)

    #expect(!settings.isEnabled)
    #expect(settings.errorMessage != nil)
}

@Test @MainActor
func runtimeMonitorStopsPollingAndProcessSamplingWhenClosed() async {
    let worker = RuntimeWorkerMonitorSpy()
    let sampler = RuntimeProcessSamplerSpy()
    let scheduler = RuntimeMonitorSchedulerSpy()
    let monitor = WorkerDiagnostics(
        client: worker,
        processSampler: sampler,
        scheduler: scheduler
    )

    monitor.startMonitoring()
    await monitor.waitForPendingRefreshes()
    #expect(worker.requestCount == 2)
    #expect(sampler.sampledProcessIDs == [101, 102])

    scheduler.fire()
    await monitor.waitForPendingRefreshes()
    #expect(worker.requestCount == 4)

    monitor.stopMonitoring()
    scheduler.fire()
    await monitor.waitForPendingRefreshes()

    #expect(worker.requestCount == 4)
    #expect(sampler.resetCount == 1)
    #expect(scheduler.cancelCount == 1)
}

@MainActor
private final class LaunchAtLoginBackendSpy: LaunchAtLoginRegistering {
    var status: LaunchAtLoginStatus = .disabled
    var registrationError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    func register() throws {
        registerCount += 1
        if let registrationError { throw registrationError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        status = .disabled
    }
}

private enum TestLaunchAtLoginError: Error {
    case failed
}

@MainActor
private final class RuntimeWorkerMonitorSpy: WorkerMonitoring {
    private(set) var requestCount = 0

    func snapshot(for endpoint: WorkerEndpoint) async throws -> WorkerSnapshot {
        requestCount += 1
        return WorkerSnapshot(
            state: .loaded,
            modelID: endpoint == .speech ? "speech" : "formatter",
            processIdentifier: endpoint == .speech ? 101 : 102,
            usesMetal: true
        )
    }
}

@MainActor
private final class RuntimeProcessSamplerSpy: WorkerProcessSampling {
    private(set) var sampledProcessIDs: [Int32] = []
    private(set) var resetCount = 0

    func sample(processIdentifier: Int32) -> WorkerProcessResources? {
        sampledProcessIDs.append(processIdentifier)
        return WorkerProcessResources(
            physicalFootprintBytes: 1_024,
            cpuPercentage: 5
        )
    }

    func reset() {
        resetCount += 1
    }
}

@MainActor
private final class RuntimeMonitorSchedulerSpy: RuntimeMonitorScheduling {
    private var action: (@MainActor @Sendable () -> Void)?
    private(set) var cancelCount = 0

    func schedule(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> RuntimeMonitorCancellable {
        self.action = action
        return RuntimeMonitorCancellationSpy { [weak self] in
            self?.cancelCount += 1
            self?.action = nil
        }
    }

    func fire() {
        action?()
    }
}

@MainActor
private final class RuntimeMonitorCancellationSpy: RuntimeMonitorCancellable {
    private let cancellation: @MainActor () -> Void

    init(cancellation: @escaping @MainActor () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation()
    }
}
