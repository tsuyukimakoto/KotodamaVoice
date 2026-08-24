import XCTest

final class KotodamaVoiceUITests: XCTestCase {
    @MainActor
    func testSettingsModelsAndRuntimeMonitorAreReachable() {
        let application = XCUIApplication()
        application.launchEnvironment["KOTODAMA_UI_TESTING"] = "1"
        application.launch()
        application.activate()
        application.typeKey(",", modifierFlags: .command)

        let settingsWindow = application.windows.firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        settingsWindow.buttons["General"].click()
        XCTAssertEqual(
            settingsWindow.staticTexts["activation-policy"].value as? String,
            "accessory"
        )

        for title in [
            "General",
            "Speech",
            "Formatting",
            "Output",
            "Models",
        ] {
            XCTAssertTrue(settingsWindow.buttons[title].exists)
        }

        settingsWindow.buttons["Speech"].click()
        XCTAssertTrue(settingsWindow.radioGroups["speech-engine-picker"].exists)
        settingsWindow.radioButtons["外部"].click()
        XCTAssertTrue(settingsWindow.textFields["external-endpoint"].exists)

        settingsWindow.buttons["Formatting"].click()
        settingsWindow.radioButtons["外部"].click()
        XCTAssertTrue(settingsWindow.textFields["external-endpoint"].exists)

        settingsWindow.buttons["General"].click()

        settingsWindow.buttons["models-open-button"].click()
        let modelsWindow = application.windows["モデル"]
        XCTAssertTrue(modelsWindow.waitForExistence(timeout: 3))
        assertModel(
            in: modelsWindow,
            id: "whisper-large-v3-turbo-f16",
            name: "Whisper Large v3 Turbo F16",
            purpose: "文字起こし",
            size: "1.62 GB",
            source: "huggingface.co",
            license: "MIT",
            status: "未導入"
        )
        XCTAssertFalse(
            modelsWindow.staticTexts[
                "model-whisper-large-v3-turbo-f16-default"
            ].exists
        )
        assertModel(
            in: modelsWindow,
            id: "whisper-large-v3-turbo-q5-0",
            name: "Whisper Large v3 Turbo Q5_0",
            purpose: "文字起こし",
            size: "574 MB",
            source: "huggingface.co",
            license: "MIT",
            status: "未導入"
        )
        XCTAssertTrue(
            modelsWindow.staticTexts[
                "model-whisper-large-v3-turbo-q5-0-default"
            ].exists
        )
        assertModel(
            in: modelsWindow,
            id: "gemma-4-e4b-it-qat-q4-0",
            name: "Gemma 4 E4B IT QAT Q4_0",
            purpose: "文章整形",
            size: "5.15 GB",
            source: "huggingface.co",
            license: "Apache-2.0",
            status: "未導入"
        )
        modelsWindow.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(modelsWindow.waitForNonExistence(timeout: 3))

        settingsWindow.buttons["runtime-open-button"].click()
        let runtimeWindow = application.windows["Runtime Monitor"]
        XCTAssertTrue(runtimeWindow.waitForExistence(timeout: 3))
        XCTAssertFalse(runtimeWindow.staticTexts["GPU使用率"].exists)
        XCTAssertFalse(runtimeWindow.staticTexts["独立VRAM"].exists)
    }

    @MainActor
    func testDefaultPromptRemainsUnchangedAfterConfirmedCustomOverwrite() {
        let application = XCUIApplication()
        application.launchEnvironment["KOTODAMA_UI_TESTING"] = "1"
        application.launch()
        application.activate()
        application.typeKey(",", modifierFlags: .command)

        let settingsWindow = application.windows.firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        settingsWindow.buttons["Formatting"].click()
        settingsWindow.radioButtons["Default"].click()

        let defaultText = settingsWindow.staticTexts["default-prompt-text"]
        XCTAssertTrue(defaultText.waitForExistence(timeout: 3))
        let originalDefault = defaultText.value as? String
        XCTAssertFalse(originalDefault?.isEmpty ?? true)

        settingsWindow.radioButtons["Custom"].click()
        let editor = settingsWindow.textViews["custom-prompt-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("変更済みCustom Prompt")
        settingsWindow.buttons["default-prompt-import-button"].click()

        let confirmationSheet = settingsWindow.sheets.firstMatch
        XCTAssertTrue(confirmationSheet.waitForExistence(timeout: 3))
        confirmationSheet.buttons["上書き"].click()

        settingsWindow.radioButtons["Default"].click()
        XCTAssertTrue(defaultText.waitForExistence(timeout: 3))
        XCTAssertEqual(defaultText.value as? String, originalDefault)
    }

    @MainActor
    func testAccessibilityPromptOccursOnlyAfterAutoInsertConfirmation() {
        let application = XCUIApplication()
        application.launchEnvironment["KOTODAMA_UI_TESTING"] = "1"
        application.launchEnvironment["KOTODAMA_UI_TEST_ACCESSIBILITY_TRUSTED"] = "0"
        application.launch()
        application.activate()
        application.typeKey(",", modifierFlags: .command)

        let settingsWindow = application.windows.firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        settingsWindow.buttons["Output"].click()

        let promptCount = settingsWindow.staticTexts["accessibility-prompt-count"]
        XCTAssertTrue(promptCount.waitForExistence(timeout: 3))
        XCTAssertEqual(promptCount.value as? String, "0")

        settingsWindow.radioButtons["Clipboard"].click()
        XCTAssertEqual(promptCount.value as? String, "0")

        settingsWindow.radioButtons["Auto Insert"].click()
        let explanation = settingsWindow.sheets.firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 3))
        XCTAssertEqual(promptCount.value as? String, "0")
        explanation.buttons["許可を要求"].click()

        XCTAssertEqual(promptCount.value as? String, "1")
        XCTAssertEqual(
            settingsWindow.staticTexts["output-mode-value"].value as? String,
            "Clipboard"
        )
        XCTAssertTrue(
            settingsWindow.staticTexts["accessibility-permission-required"].exists
        )
    }

    @MainActor
    private func assertModel(
        in window: XCUIElement,
        id: String,
        name: String,
        purpose: String,
        size: String,
        source: String,
        license: String,
        status: String
    ) {
        let expectedValues = [
            ("name", name),
            ("purpose", purpose),
            ("size", size),
            ("source", source),
            ("license", license),
            ("status", status),
        ]
        for (field, expectedValue) in expectedValues {
            let text = window.staticTexts["model-\(id)-\(field)"]
            XCTAssertTrue(text.exists)
            XCTAssertEqual(text.value as? String, expectedValue)
        }
    }
}
