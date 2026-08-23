import XCTest

final class KotodamaVoiceUITests: XCTestCase {
    @MainActor
    func testSettingsModelsAndRuntimeMonitorAreReachable() {
        let application = XCUIApplication()
        application.launchEnvironment["KOTODAMA_UI_TESTING"] = "1"
        application.launch()
        application.activate()
        application.typeKey(",", modifierFlags: .command)

        let settingsWindow = application.windows["General"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
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
        XCTAssertTrue(
            application.windows["Runtime Monitor"].waitForExistence(timeout: 3)
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
