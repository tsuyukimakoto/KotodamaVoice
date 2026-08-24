import Foundation
import Testing
@testable import KotodamaVoice

@Test @MainActor
func debugLoggingIsDisabledWithoutCreatingFilesByDefault() {
    let fixture = DebugLogFixture()

    #expect(fixture.settings.isEnabled == false)
    #expect(fixture.settings.currentLogFileURL == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.logsURL.path))
}

@Test @MainActor
func enablingDebugLoggingCreatesPrivateTimestampedSessionFile() throws {
    let fixture = DebugLogFixture()

    fixture.settings.setEnabled(true)

    let fileURL = try #require(fixture.settings.currentLogFileURL)
    #expect(fileURL.lastPathComponent == "KotodamaVoice-20260825-123456-789.log")
    #expect(fixture.settings.isEnabled)
    #expect(fixture.defaults.bool(forKey: "debugLogging.enabled"))

    let directoryAttributes = try FileManager.default.attributesOfItem(
        atPath: fixture.logsURL.path
    )
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test @MainActor
func enabledPreferenceStartsANewSessionAndOpenUsesTheLogDirectory() throws {
    let fixture = DebugLogFixture(enabled: true)

    let fileURL = try #require(fixture.settings.currentLogFileURL)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))

    fixture.settings.openLogDirectory()
    #expect(fixture.openedURLs == [fixture.logsURL])
}

@Test @MainActor
func disablingDebugLoggingStopsWritingWithoutDeletingTheSessionFile() throws {
    let fixture = DebugLogFixture()
    fixture.settings.setEnabled(true)
    let fileURL = try #require(fixture.settings.currentLogFileURL)

    fixture.settings.record(
        DebugErrorEvent(
            area: .autoInsert,
            stage: .pasteAction,
            error: .accessibilityAPI,
            code: -25_204,
            bundleIdentifier: "dev.zed.Zed",
            role: "AXTextArea",
            requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )
    )
    let written = try Data(contentsOf: fileURL)
    fixture.settings.setEnabled(false)
    fixture.settings.record(
        DebugErrorEvent(
            area: .autoInsert,
            stage: .resultVerification,
            error: .verificationFailed
        )
    )

    #expect(fixture.settings.currentLogFileURL == nil)
    #expect(try Data(contentsOf: fileURL) == written)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
}

@Test @MainActor
func debugLogContainsOnlyAllowlistedDiagnostics() throws {
    let fixture = DebugLogFixture()
    fixture.settings.setEnabled(true)
    let fileURL = try #require(fixture.settings.currentLogFileURL)

    fixture.settings.record(
        DebugErrorEvent(
            area: .autoInsert,
            stage: .selectedTextRange,
            error: .invalidSelectionRange,
            code: -25_205,
            bundleIdentifier: "dev.zed.Zed",
            role: "AXTextArea"
        )
    )

    let contents = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(contents.contains(#""area":"auto_insert""#))
    #expect(contents.contains(#""stage":"selected_text_range""#))
    #expect(contents.contains(#""error":"invalid_selection_range""#))
    #expect(contents.contains(#""code":-25205"#))
    #expect(contents.contains(#""bundle_id":"dev.zed.Zed""#))
    #expect(contents.contains(#""role":"AXTextArea""#))

    let line = try #require(contents.split(separator: "\n").first)
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )
    #expect(
        Set(object.keys) == [
            "timestamp",
            "area",
            "stage",
            "error",
            "code",
            "bundle_id",
            "role",
        ]
    )

    for forbiddenKey in [
        "audio",
        "transcript",
        "prompt",
        "formatted_text",
        "clipboard",
        "api_key",
        "window_title",
        "accessibility_label",
    ] {
        #expect(!contents.contains(forbiddenKey))
    }
}

@MainActor
private final class DebugLogFixture {
    let rootURL: URL
    let logsURL: URL
    let defaultsSuiteName: String
    let defaults: UserDefaults
    private(set) var openedURLs: [URL] = []
    lazy var settings = DebugLogSettingsStore(
        defaults: defaults,
        logsDirectoryURL: logsURL,
        now: {
            Date(timeIntervalSince1970: 1_787_628_896.789)
        },
        openDirectory: { [weak self] url in
            self?.openedURLs.append(url)
        }
    )

    init(enabled: Bool = false) {
        rootURL = FileManager.default.temporaryDirectory.appending(
            path: "KotodamaVoiceDebugLogTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        logsURL = rootURL.appending(path: "logs", directoryHint: .isDirectory)
        defaultsSuiteName = "KotodamaVoiceDebugLogTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults.set(enabled, forKey: "debugLogging.enabled")
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

}
