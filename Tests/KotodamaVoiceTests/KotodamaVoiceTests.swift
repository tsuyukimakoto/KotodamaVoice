import Foundation
import KotodamaCore
import Security
import Testing
@testable import KotodamaVoice

@Test func applicationModuleLoads() {
    #expect(true)
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
    let suiteName = "jp.tsuyuki.KotodamaVoiceTests.\(UUID().uuidString)"
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
