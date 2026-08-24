@preconcurrency import ApplicationServices
import Foundation
import Observation

enum OutputMode: String, CaseIterable, Identifiable {
    case clipboard
    case autoInsert

    var id: Self { self }

    var displayName: String {
        switch self {
        case .clipboard:
            "Clipboard"
        case .autoInsert:
            "Auto Insert"
        }
    }
}

enum AutoInsertPermissionResult: Equatable {
    case enabled
    case permissionRequired
}

@MainActor
protocol AccessibilityPermissionChecking: AnyObject {
    func check(prompt: Bool) -> Bool
}

@MainActor
final class SystemAccessibilityPermissionAdapter: AccessibilityPermissionChecking {
    func check(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

@Observable
@MainActor
final class OutputSettingsStore {
    private enum Key {
        static let mode = "output.mode"
    }

    private let defaults: UserDefaults
    private let permission: AccessibilityPermissionChecking

    private(set) var mode: OutputMode
    private(set) var permissionResult: AutoInsertPermissionResult?
    private(set) var permissionPromptRequestCount = 0
    private(set) var isAwaitingAccessibilityPermission = false

    var selectedMode: OutputMode {
        isAwaitingAccessibilityPermission ? .autoInsert : mode
    }

    init(
        defaults: UserDefaults = .standard,
        permission: AccessibilityPermissionChecking = SystemAccessibilityPermissionAdapter()
    ) {
        self.defaults = defaults
        self.permission = permission
        mode = OutputMode(rawValue: defaults.string(forKey: Key.mode) ?? "")
            ?? .clipboard
    }

    func selectClipboard() {
        mode = .clipboard
        permissionResult = nil
        isAwaitingAccessibilityPermission = false
        persistMode()
    }

    @discardableResult
    func requestAutoInsertPermission() -> AutoInsertPermissionResult {
        permissionPromptRequestCount += 1
        return applyPermissionResult(permission.check(prompt: true))
    }

    @discardableResult
    func recheckAutoInsertPermission() -> AutoInsertPermissionResult {
        applyPermissionResult(permission.check(prompt: false))
    }

    func applicationDidBecomeActive() {
        guard isAwaitingAccessibilityPermission else { return }
        recheckAutoInsertPermission()
    }

    private func applyPermissionResult(_ isTrusted: Bool) -> AutoInsertPermissionResult {
        let result: AutoInsertPermissionResult
        if isTrusted {
            mode = .autoInsert
            isAwaitingAccessibilityPermission = false
            result = .enabled
        } else {
            mode = .clipboard
            isAwaitingAccessibilityPermission = true
            result = .permissionRequired
        }
        permissionResult = result
        persistMode()
        return result
    }

    private func persistMode() {
        defaults.set(mode.rawValue, forKey: Key.mode)
    }
}

#if DEBUG
    @MainActor
    final class UITestAccessibilityPermissionAdapter: AccessibilityPermissionChecking {
        private let isTrusted: Bool

        init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            isTrusted = environment["KOTODAMA_UI_TEST_ACCESSIBILITY_TRUSTED"] == "1"
        }

        func check(prompt: Bool) -> Bool {
            isTrusted
        }
    }
#endif
