import XCTest

final class GlossaryUITests: XCTestCase {
    @MainActor
    func testGlossaryCanBeEditedAndSettingsPersist() throws {
        let app = XCUIApplication()
        let root = glossaryTestDirectory()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launchEnvironment["KOTODAMA_UI_TESTING"] = "1"
        app.launchEnvironment["KOTODAMA_UI_TEST_SUITE"] =
            "com.tsuyukimakoto.GlossaryUITests.\(UUID())"
        app.launchEnvironment["KOTODAMA_UI_TEST_GLOSSARY_DIRECTORY"] = root.path
        app.launch()
        let selection = app.windows["出力方式を選択"]
        if selection.waitForExistence(timeout: 5) {
            selection.buttons["choose-clipboard-output"].click()
        }
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.buttons["用語集"].waitForExistence(timeout: 5))
        window.buttons["用語集"].click()
        XCTAssertTrue(window.buttons["glossary-add"].waitForExistence(timeout: 3))
        window.buttons["glossary-add"].click()
        let sheet = window.sheets.firstMatch
        sheet.textFields["glossary-term"].click()
        sheet.textFields["glossary-term"].typeText("Codex")
        sheet.buttons["glossary-save"].click()
        XCTAssertTrue(window.staticTexts["Codex"].waitForExistence(timeout: 3))
        window.switches["glossary-speech"].click()
        window.switches["glossary-formatting"].click()
        window.switches["glossary-diagnostics"].click()
        XCTAssertFalse(window.staticTexts["glossary-log-error"].exists)
        XCTAssertTrue(window.staticTexts["glossary-formatter-inactive"].exists)
        app.terminate()
        app.launchEnvironment["KOTODAMA_UI_TEST_GLOSSARY_OMITTED"] = "1"
        app.launch()
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let restored = app.windows.firstMatch
        restored.buttons["用語集"].click()
        XCTAssertTrue(restored.staticTexts["Codex"].waitForExistence(timeout: 3))
        XCTAssertEqual((restored.switches["glossary-speech"].value as? NSNumber)?.boolValue, true)
        XCTAssertTrue(restored.buttons["glossary-open-logs"].exists)
        XCTAssertTrue(restored.staticTexts["glossary-omitted"].exists)
        XCTAssertTrue(restored.staticTexts["glossary-diagnostics-explanation"].exists)
        restored.buttons["glossary-open-logs"].click()
        app.activate()
        restored.buttons["glossary-edit"].firstMatch.click()
        let edit = restored.sheets.firstMatch
        edit.textFields["glossary-term"].click()
        edit.textFields["glossary-term"].typeKey("a", modifierFlags: .command)
        edit.textFields["glossary-term"].typeText("KotodamaVoice")
        edit.buttons["glossary-save"].click()
        XCTAssertTrue(restored.staticTexts["KotodamaVoice"].waitForExistence(timeout: 3))
        restored.buttons["glossary-delete"].firstMatch.click()
        XCTAssertTrue(restored.staticTexts["KotodamaVoice"].waitForNonExistence(timeout: 3))
        restored.buttons["Speech"].click()
        restored.radioButtons["外部"].click()
        restored.buttons["用語集"].click()
        XCTAssertTrue(restored.staticTexts["glossary-speech-unsupported"].exists)
        restored.buttons["Formatting"].click()
        restored.radioButtons["外部"].click()
        let endpoint = restored.textFields["external-endpoint"]
        endpoint.click()
        endpoint.typeText("https://www.tsuyukimakoto.com/v1/responses")
        restored.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -300)
        restored.textFields["external-model"].click()
        restored.textFields["external-model"].typeText("fixture")
        restored.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
        restored.buttons["external-save"].click()
        restored.sheets.firstMatch.buttons["許可して保存"].click()
        restored.buttons["用語集"].click()
        XCTAssertTrue(restored.staticTexts["glossary-consent-missing"].waitForExistence(timeout: 3))
        restored.buttons["glossary-consent"].click()
        restored.sheets.firstMatch.buttons["許可"].click()
        XCTAssertTrue(
            restored.staticTexts["glossary-consent-missing"].waitForNonExistence(timeout: 3))

    }
}

final class GlossaryErrorUITests: XCTestCase {
    @MainActor
    func testCorruptGlossaryAndUnavailableLogDirectoryAreVisible() throws {
        let root = glossaryTestDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("broken glossary".utf8).write(to: root.appending(path: "glossary.json"))
        try Data().write(to: root.appending(path: "logs"))
        let app = XCUIApplication()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launchEnvironment["KOTODAMA_UI_TEST_SUITE"] =
            "com.tsuyukimakoto.GlossaryErrorUITests.\(UUID())"
        app.launchEnvironment["KOTODAMA_UI_TESTING"] = "1"
        app.launchEnvironment["KOTODAMA_UI_TEST_GLOSSARY_DIRECTORY"] = root.path
        app.launch()
        let selection = app.windows["出力方式を選択"]
        if selection.waitForExistence(timeout: 5) {
            selection.buttons["choose-clipboard-output"].click()
        }
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let window = app.windows.firstMatch
        window.buttons["用語集"].click()
        XCTAssertTrue(window.staticTexts["glossary-error"].waitForExistence(timeout: 3))
        XCTAssertFalse(window.buttons["glossary-add"].isEnabled)
        window.switches["glossary-diagnostics"].click()
        XCTAssertTrue(window.staticTexts["glossary-log-error"].waitForExistence(timeout: 3))
        XCTAssertEqual(
            try String(contentsOf: root.appending(path: "glossary.json"), encoding: .utf8),
            "broken glossary")
    }
}

private func glossaryTestDirectory() -> URL {
    let path = FileManager.default.temporaryDirectory.path
    // The logger rejects symlinks, including the system /var alias.
    let canonical = path.hasPrefix("/var/") ? "/private" + path : path
    return URL(fileURLWithPath: canonical).appending(path: UUID().uuidString)
}
