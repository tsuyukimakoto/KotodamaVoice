import XCTest

final class KotodamaVoiceUITests: XCTestCase {
    @MainActor
    func testSettingsModelsAndRuntimeMonitorAreReachable() {
        let application = XCUIApplication()
        application.launchEnvironment["KOTODAMA_UI_TESTING"] = "1"
        application.launch()

        let settingsWindow = application.windows.firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        XCTAssertEqual(
            settingsWindow.staticTexts["activation-policy"].label,
            "accessory"
        )

        for identifier in [
            "general-settings",
            "speech-settings",
            "formatting-settings",
            "output-settings",
            "models-settings",
        ] {
            XCTAssertTrue(settingsWindow.buttons[identifier].exists)
        }

        settingsWindow.buttons["models-open-button"].click()
        XCTAssertTrue(application.windows["モデル"].waitForExistence(timeout: 3))

        settingsWindow.buttons["runtime-open-button"].click()
        XCTAssertTrue(
            application.windows["Runtime Monitor"].waitForExistence(timeout: 3)
        )
    }
}
