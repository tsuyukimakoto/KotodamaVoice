import Foundation
import Testing
@testable import KotodamaVoice

@Test @MainActor
func outputSettingsDoNotInspectAccessibilityAtInitializationOrForClipboard() {
    let defaults = isolatedOutputDefaults()
    let permission = AccessibilityPermissionSpy(isTrusted: false)
    let settings = OutputSettingsStore(defaults: defaults, permission: permission)

    settings.selectClipboard()

    #expect(settings.mode == .clipboard)
    #expect(permission.promptValues.isEmpty)
    #expect(settings.permissionPromptRequestCount == 0)
}

@Test @MainActor
func autoInsertSelectionPromptsAndKeepsClipboardUntilTrusted() {
    let defaults = isolatedOutputDefaults()
    let permission = AccessibilityPermissionSpy(isTrusted: false)
    let settings = OutputSettingsStore(defaults: defaults, permission: permission)

    let result = settings.requestAutoInsertPermission()

    #expect(result == .permissionRequired)
    #expect(settings.mode == .clipboard)
    #expect(permission.promptValues == [true])
    #expect(settings.permissionPromptRequestCount == 1)
}

@Test @MainActor
func autoInsertIsPersistedOnlyAfterAccessibilityIsTrusted() {
    let defaults = isolatedOutputDefaults()
    let permission = AccessibilityPermissionSpy(isTrusted: true)
    let settings = OutputSettingsStore(defaults: defaults, permission: permission)

    let result = settings.requestAutoInsertPermission()

    #expect(result == .enabled)
    #expect(settings.mode == .autoInsert)
    #expect(OutputSettingsStore(defaults: defaults, permission: permission).mode == .autoInsert)
    #expect(permission.promptValues == [true])
}

@Test @MainActor
func accessibilityRecheckDoesNotPromptAgain() {
    let defaults = isolatedOutputDefaults()
    let permission = AccessibilityPermissionSpy(isTrusted: false)
    let settings = OutputSettingsStore(defaults: defaults, permission: permission)
    _ = settings.requestAutoInsertPermission()
    permission.isTrusted = true

    let result = settings.recheckAutoInsertPermission()

    #expect(result == .enabled)
    #expect(settings.mode == .autoInsert)
    #expect(permission.promptValues == [true, false])
    #expect(settings.permissionPromptRequestCount == 1)
}

@MainActor
private final class AccessibilityPermissionSpy: AccessibilityPermissionChecking {
    var isTrusted: Bool
    private(set) var promptValues: [Bool] = []

    init(isTrusted: Bool) {
        self.isTrusted = isTrusted
    }

    func check(prompt: Bool) -> Bool {
        promptValues.append(prompt)
        return isTrusted
    }
}

private func isolatedOutputDefaults() -> UserDefaults {
    let suiteName = "OutputSettingsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
