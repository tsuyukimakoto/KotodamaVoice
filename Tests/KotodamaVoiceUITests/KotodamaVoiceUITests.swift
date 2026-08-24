import XCTest

final class KotodamaVoiceUITests: XCTestCase {
    @MainActor
    func testSettingsModelsAndRuntimeMonitorAreReachable() {
        let application = XCUIApplication()
        application.launchEnvironment["KOTODAMA_UI_TESTING"] = "1"
        application.launch()
        chooseClipboardIfNeeded(in: application)
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
        chooseClipboardIfNeeded(in: application)
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
    func testBuiltInFormatterIsSavedOnlyAfterModelInstallation() {
        let application = XCUIApplication()
        application.launchEnvironment["KOTODAMA_UI_TESTING"] = "1"
        application.launchEnvironment["KOTODAMA_UI_TEST_MODEL_INSTALL_RESULT"] = "success"
        application.launch()
        chooseClipboardIfNeeded(in: application)
        application.activate()
        application.typeKey(",", modifierFlags: .command)

        let settingsWindow = application.windows.firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        settingsWindow.buttons["Formatting"].click()
        XCTAssertEqual(
            settingsWindow.staticTexts["formatter-engine-value"].value as? String,
            "Off"
        )

        settingsWindow.radioButtons["内蔵"].click()
        let confirmation = settingsWindow.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmation.staticTexts["モデルを取得しますか？"].exists)
        let modelDetails = confirmation.staticTexts.matching(
            NSPredicate(
                format: "value CONTAINS %@",
                "Gemma 4 E4B IT QAT Q4_0"
            )
        ).firstMatch
        XCTAssertTrue(modelDetails.exists)
        XCTAssertEqual(
            application.staticTexts["formatter-engine-value"].value as? String,
            "Off"
        )
        confirmation.buttons["キャンセル"].click()
        XCTAssertEqual(
            application.staticTexts["formatter-engine-value"].value as? String,
            "Off"
        )

        settingsWindow.radioButtons["内蔵"].click()
        let secondConfirmation = settingsWindow.sheets.firstMatch
        XCTAssertTrue(secondConfirmation.waitForExistence(timeout: 3))
        secondConfirmation.buttons["取得して内蔵を使用"].click()

        let modelsWindow = application.windows["モデル"]
        XCTAssertTrue(modelsWindow.waitForExistence(timeout: 3))
        let status = modelsWindow.staticTexts[
            "model-gemma-4-e4b-it-qat-q4-0-status"
        ]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(status.value as? String, "導入済み")
        XCTAssertEqual(
            application.staticTexts["formatter-engine-value"].value as? String,
            "内蔵"
        )

        modelsWindow.buttons["delete-gemma-4-e4b-it-qat-q4-0"].click()
        let notInstalled = NSPredicate(format: "value == %@", "未導入")
        expectation(for: notInstalled, evaluatedWith: status)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(
            application.staticTexts["formatter-engine-value"].value as? String,
            "Off"
        )
    }

    @MainActor
    func testInitialOutputSelectionChoosesClipboardWithoutPermission() {
        let application = XCUIApplication()
        application.launchEnvironment["KOTODAMA_UI_TESTING"] = "1"
        application.launchEnvironment["KOTODAMA_UI_TEST_ACCESSIBILITY_TRUSTED"] = "0"
        application.launch()

        let selectionWindow = application.windows["出力方式を選択"]
        XCTAssertTrue(selectionWindow.waitForExistence(timeout: 5))
        let promptCount = selectionWindow.staticTexts["output-selection-prompt-count"]
        XCTAssertTrue(promptCount.waitForExistence(timeout: 3))
        XCTAssertEqual(promptCount.value as? String, "0")

        selectionWindow.buttons["choose-clipboard-output"].click()
        XCTAssertTrue(selectionWindow.waitForNonExistence(timeout: 3))

        application.typeKey(",", modifierFlags: .command)
        let settingsWindow = application.windows.firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        settingsWindow.buttons["Output"].click()
        XCTAssertEqual(
            settingsWindow.staticTexts["output-mode-value"].value as? String,
            "Clipboard"
        )
        XCTAssertEqual(
            settingsWindow.staticTexts["accessibility-prompt-count"].value as? String,
            "0"
        )
    }

    @MainActor
    func testDismissedOutputSelectionReopensBeforeRecording() {
        let application = XCUIApplication()
        application.launchEnvironment["KOTODAMA_UI_TESTING"] = "1"
        application.launch()

        let selectionWindow = application.windows["出力方式を選択"]
        XCTAssertTrue(selectionWindow.waitForExistence(timeout: 5))
        selectionWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(selectionWindow.waitForNonExistence(timeout: 3))

        application.typeKey(" ", modifierFlags: [.control, .option])

        XCTAssertTrue(selectionWindow.waitForExistence(timeout: 3))
        XCTAssertEqual(
            selectionWindow.staticTexts["output-selection-prompt-count"].value as? String,
            "0"
        )
    }

    @MainActor
    func testAutoInsertRemainsUnsetUntilAccessibilityIsTrusted() {
        let application = XCUIApplication()
        application.launchEnvironment["KOTODAMA_UI_TESTING"] = "1"
        application.launchEnvironment["KOTODAMA_UI_TEST_ACCESSIBILITY_TRUSTED"] = "0"
        application.launch()

        let selectionWindow = application.windows["出力方式を選択"]
        XCTAssertTrue(selectionWindow.waitForExistence(timeout: 5))
        let promptCount = selectionWindow.staticTexts["output-selection-prompt-count"]
        XCTAssertEqual(promptCount.value as? String, "0")

        selectionWindow.buttons["choose-auto-insert-output"].click()
        let explanation = selectionWindow.sheets.firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 3))
        XCTAssertEqual(promptCount.value as? String, "0")
        explanation.buttons["許可を要求"].click()

        XCTAssertEqual(promptCount.value as? String, "1")
        XCTAssertTrue(
            selectionWindow.staticTexts["output-selection-permission-required"].exists
        )
        XCTAssertTrue(selectionWindow.exists)
    }

    @MainActor
    private func chooseClipboardIfNeeded(in application: XCUIApplication) {
        let selectionWindow = application.windows["出力方式を選択"]
        if selectionWindow.waitForExistence(timeout: 5) {
            selectionWindow.buttons["choose-clipboard-output"].click()
            XCTAssertTrue(selectionWindow.waitForNonExistence(timeout: 3))
        }
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
