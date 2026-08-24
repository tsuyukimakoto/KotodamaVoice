import AppKit
import Foundation
import Observation

enum DebugLogArea: String, Codable, Sendable {
    case autoInsert = "auto_insert"
    case audio
    case hotKey = "hot_key"
    case output
    case speech
}

enum DebugLogStage: String, Codable, Sendable {
    case accessibilityPermission = "accessibility_permission"
    case focusedApplication = "focused_application"
    case focusedElement = "focused_element"
    case role
    case selectedTextRange = "selected_text_range"
    case selectionSettable = "selection_settable"
    case targetCapture = "target_capture"
    case targetRevalidation = "target_revalidation"
    case valueRead = "value_read"
    case pasteboardWrite = "pasteboard_write"
    case pasteMenuBar = "paste_menu_bar"
    case pasteMenuItem = "paste_menu_item"
    case pasteAction = "paste_action"
    case resultVerification = "result_verification"
    case recordingStart = "recording_start"
    case recording = "recording"
    case transcription
    case delivery
    case hotKeyRegistration = "hot_key_registration"
}

enum DebugLogError: String, Codable, Sendable {
    case accessibilityAPI = "accessibility_api"
    case applicationChanged = "application_changed"
    case clipboardWriteFailed = "clipboard_write_failed"
    case elementChanged = "element_changed"
    case elementNotEditable = "element_not_editable"
    case focusedElementChanged = "focused_element_changed"
    case inputDeviceUnavailable = "input_device_unavailable"
    case invalidAttribute = "invalid_attribute"
    case invalidSelectionRange = "invalid_selection_range"
    case microphonePermissionDenied = "microphone_permission_denied"
    case missingAccessibilityElement = "missing_accessibility_element"
    case noCapturedTarget = "no_captured_target"
    case noFrontmostApplication = "no_frontmost_application"
    case pasteActionUnavailable = "paste_action_unavailable"
    case pasteboardWriteFailed = "pasteboard_write_failed"
    case rangeOutOfBounds = "range_out_of_bounds"
    case roleChanged = "role_changed"
    case selectionChanged = "selection_changed"
    case speechModelUnavailable = "speech_model_unavailable"
    case speechTranscriptionFailed = "speech_transcription_failed"
    case targetNoLongerFrontmost = "target_no_longer_frontmost"
    case verificationFailed = "verification_failed"
    case hotKeyConflict = "hot_key_conflict"
    case systemFailure = "system_failure"
}

struct DebugErrorEvent: Equatable, Sendable {
    let area: DebugLogArea
    let stage: DebugLogStage
    let error: DebugLogError
    let code: Int32?
    let bundleIdentifier: String?
    let role: String?
    let requestID: UUID?

    init(
        area: DebugLogArea,
        stage: DebugLogStage,
        error: DebugLogError,
        code: Int32? = nil,
        bundleIdentifier: String? = nil,
        role: String? = nil,
        requestID: UUID? = nil
    ) {
        self.area = area
        self.stage = stage
        self.error = error
        self.code = code
        self.bundleIdentifier = bundleIdentifier
        self.role = role
        self.requestID = requestID
    }

    func withRequestID(_ requestID: UUID?) -> DebugErrorEvent {
        DebugErrorEvent(
            area: area,
            stage: stage,
            error: error,
            code: code,
            bundleIdentifier: bundleIdentifier,
            role: role,
            requestID: requestID ?? self.requestID
        )
    }
}

@MainActor
protocol DebugErrorLogging: AnyObject {
    func record(_ event: DebugErrorEvent)
}

@Observable
@MainActor
final class DebugLogSettingsStore: DebugErrorLogging {
    private enum Key {
        static let enabled = "debugLogging.enabled"
    }

    private struct Record: Encodable {
        let timestamp: String
        let area: DebugLogArea
        let stage: DebugLogStage
        let error: DebugLogError
        let code: Int32?
        let bundleIdentifier: String?
        let role: String?
        let requestID: UUID?

        enum CodingKeys: String, CodingKey {
            case timestamp
            case area
            case stage
            case error
            case code
            case bundleIdentifier = "bundle_id"
            case role
            case requestID = "request_id"
        }
    }

    private(set) var isEnabled: Bool
    private(set) var currentLogFileURL: URL?
    private(set) var errorMessage: String?

    let logsDirectoryURL: URL

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let now: () -> Date
    private let openDirectory: (URL) -> Void
    private var fileHandle: FileHandle?

    init(
        defaults: UserDefaults,
        logsDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".kotodamavoice/logs", directoryHint: .isDirectory),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        openDirectory: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.defaults = defaults
        self.logsDirectoryURL = logsDirectoryURL
        self.fileManager = fileManager
        self.now = now
        self.openDirectory = openDirectory
        isEnabled = defaults.bool(forKey: Key.enabled)

        if isEnabled {
            startSessionOrDisable()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            isEnabled = true
            defaults.set(true, forKey: Key.enabled)
            startSessionOrDisable()
        } else {
            stopSession()
            isEnabled = false
            defaults.set(false, forKey: Key.enabled)
            errorMessage = nil
        }
    }

    func openLogDirectory() {
        guard fileManager.fileExists(atPath: logsDirectoryURL.path) else { return }
        openDirectory(logsDirectoryURL)
    }

    func record(_ event: DebugErrorEvent) {
        guard isEnabled, let fileHandle else { return }
        let record = Record(
            timestamp: Self.timestampFormatter.string(from: now()),
            area: event.area,
            stage: event.stage,
            error: event.error,
            code: event.code,
            bundleIdentifier: event.bundleIdentifier,
            role: event.role,
            requestID: event.requestID
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(record)
            data.append(0x0A)
            try fileHandle.write(contentsOf: data)
            try fileHandle.synchronize()
        } catch {
            errorMessage = "デバッグログへ書き込めませんでした"
            stopSession()
            isEnabled = false
            defaults.set(false, forKey: Key.enabled)
        }
    }

    private func startSessionOrDisable() {
        do {
            try fileManager.createDirectory(
                at: logsDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: logsDirectoryURL.path
            )
            let fileURL = uniqueLogFileURL(for: now())
            guard fileManager.createFile(
                atPath: fileURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            fileHandle = try FileHandle(forWritingTo: fileURL)
            currentLogFileURL = fileURL
            errorMessage = nil
        } catch {
            stopSession()
            isEnabled = false
            defaults.set(false, forKey: Key.enabled)
            errorMessage = "デバッグログを開始できませんでした"
        }
    }

    private func stopSession() {
        try? fileHandle?.close()
        fileHandle = nil
        currentLogFileURL = nil
    }

    private func uniqueLogFileURL(for date: Date) -> URL {
        let stem = "KotodamaVoice-\(Self.filenameFormatter.string(from: date))"
        var candidate = logsDirectoryURL.appending(
            path: "\(stem).log",
            directoryHint: .notDirectory
        )
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = logsDirectoryURL.appending(
                path: "\(stem)-\(suffix).log",
                directoryHint: .notDirectory
            )
            suffix += 1
        }
        return candidate
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct AutoInsertDiagnosticError: Error {
    let event: DebugErrorEvent
    let underlyingError: Error
}

func autoInsertDiagnosticError(
    _ error: Error,
    stage: DebugLogStage,
    target: AutoInsertTargetObservation
) -> AutoInsertDiagnosticError {
    if let diagnostic = error as? AutoInsertDiagnosticError {
        return diagnostic
    }
    let event = autoInsertDebugEvent(for: error, defaultStage: stage)
    return AutoInsertDiagnosticError(
        event: DebugErrorEvent(
            area: .autoInsert,
            stage: stage,
            error: event.error,
            code: event.code,
            bundleIdentifier: target.bundleIdentifier,
            role: target.role
        ),
        underlyingError: error
    )
}

func autoInsertDebugEvent(
    for error: Error,
    defaultStage: DebugLogStage,
    requestID: UUID? = nil
) -> DebugErrorEvent {
    if let diagnostic = error as? AutoInsertDiagnosticError {
        return diagnostic.event.withRequestID(requestID)
    }

    let mapped: (DebugLogStage, DebugLogError, Int32?)
    switch error {
    case AutoInsertTargetObservationError.noFrontmostApplication:
        mapped = (.focusedApplication, .noFrontmostApplication, nil)
    case let AutoInsertTargetObservationError.accessibilityError(code):
        mapped = (defaultStage, .accessibilityAPI, code)
    case AutoInsertTargetObservationError.invalidAttribute:
        mapped = (defaultStage, .invalidAttribute, nil)
    case AutoInsertTargetObservationError.invalidSelectionRange:
        mapped = (.selectedTextRange, .invalidSelectionRange, nil)
    case AutoInsertTargetValidationError.noCapturedTarget:
        mapped = (.targetRevalidation, .noCapturedTarget, nil)
    case AutoInsertTargetValidationError.applicationChanged:
        mapped = (.targetRevalidation, .applicationChanged, nil)
    case AutoInsertTargetValidationError.elementChanged:
        mapped = (.targetRevalidation, .elementChanged, nil)
    case AutoInsertTargetValidationError.roleChanged:
        mapped = (.targetRevalidation, .roleChanged, nil)
    case AutoInsertTargetValidationError.elementNotEditable:
        mapped = (.targetRevalidation, .elementNotEditable, nil)
    case AutoInsertTargetValidationError.selectionChanged,
        AutoInsertTextWriterError.selectionChanged:
        mapped = (.targetRevalidation, .selectionChanged, nil)
    case AutoInsertTextWriterError.missingAccessibilityElement:
        mapped = (.valueRead, .missingAccessibilityElement, nil)
    case let AutoInsertTextWriterError.accessibilityError(code):
        mapped = (defaultStage, .accessibilityAPI, code)
    case AutoInsertTextWriterError.invalidAttribute:
        mapped = (defaultStage, .invalidAttribute, nil)
    case AutoInsertTextWriterError.invalidSelectionRange:
        mapped = (.selectedTextRange, .invalidSelectionRange, nil)
    case AutoInsertTextWriterError.rangeOutOfBounds:
        mapped = (.valueRead, .rangeOutOfBounds, nil)
    case AutoInsertTextWriterError.pasteboardWriteFailed:
        mapped = (.pasteboardWrite, .pasteboardWriteFailed, nil)
    case AutoInsertTextWriterError.pasteActionUnavailable:
        mapped = (.pasteMenuItem, .pasteActionUnavailable, nil)
    case AutoInsertTextWriterError.targetNoLongerFrontmost:
        mapped = (.targetRevalidation, .targetNoLongerFrontmost, nil)
    case AutoInsertTextWriterError.focusedElementChanged:
        mapped = (.targetRevalidation, .focusedElementChanged, nil)
    case AutoInsertTextWriterError.verificationFailed:
        mapped = (.resultVerification, .verificationFailed, nil)
    default:
        mapped = (defaultStage, .systemFailure, nil)
    }
    return DebugErrorEvent(
        area: .autoInsert,
        stage: mapped.0,
        error: mapped.1,
        code: mapped.2,
        requestID: requestID
    )
}
