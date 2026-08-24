import Foundation
import Testing
@testable import KotodamaVoice

@Test func bundledDefaultFormattingPromptIsVersionedAndProtectsFacts() throws {
    let rootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(
        contentsOf: rootURL.appending(path: "Resources/FormattingPrompt-v1.json")
    )
    let evaluationObject = try JSONSerialization.jsonObject(
        with: Data(
            contentsOf: rootURL.appending(
                path: "Config/FormatterEvaluationCases.json"
            )
        )
    )
    let evaluation = try #require(evaluationObject as? [String: Any])

    let prompt = try DefaultFormattingPromptResource.decode(data)

    #expect(prompt.schemaVersion == 1)
    #expect(prompt.identifier == "kotodama-default-ja")
    #expect(prompt.version == 1)
    #expect(prompt.text.contains("数値"))
    #expect(prompt.text.contains("日付"))
    #expect(prompt.text.contains("固有名詞"))
    #expect(prompt.text.contains("情報の追加"))
    #expect(prompt.text.contains("本文だけ"))
    #expect(prompt.text == evaluation["prompt"] as? String)
}

@Test @MainActor
func customFormattingPromptPersistsWithoutChangingDefaultResource() throws {
    let suiteName = "jp.tsuyuki.KotodamaVoiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let defaultPrompt = VersionedFormattingPrompt(
        schemaVersion: 1,
        identifier: "fixture-default",
        version: 3,
        text: "変更されないDefault"
    )
    let settings = FormatterSettingsStore(
        defaults: defaults,
        defaultPrompt: defaultPrompt
    )

    settings.setPromptSource(.custom)
    settings.setCustomPrompt("ユーザーが編集したPrompt")

    let restored = FormatterSettingsStore(
        defaults: defaults,
        defaultPrompt: defaultPrompt
    )
    #expect(restored.promptSource == .custom)
    #expect(restored.customPrompt == "ユーザーが編集したPrompt")
    #expect(restored.defaultPrompt == defaultPrompt)
    #expect(restored.activePrompt == "ユーザーが編集したPrompt")
}

@Test @MainActor
func importingDefaultRequiresConfirmationBeforeReplacingModifiedCustomPrompt() throws {
    let suiteName = "jp.tsuyuki.KotodamaVoiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let defaultPrompt = VersionedFormattingPrompt(
        schemaVersion: 1,
        identifier: "fixture-default",
        version: 4,
        text: "Default本文"
    )
    let settings = FormatterSettingsStore(
        defaults: defaults,
        defaultPrompt: defaultPrompt
    )
    settings.setCustomPrompt("変更済みCustom")

    #expect(settings.importDefaultIntoCustom() == .requiresConfirmation)
    #expect(settings.customPrompt == "変更済みCustom")
    #expect(settings.defaultPrompt == defaultPrompt)

    #expect(
        settings.importDefaultIntoCustom(overwriteConfirmed: true) == .imported
    )
    #expect(settings.promptSource == .custom)
    #expect(settings.customPrompt == "Default本文")
    #expect(settings.defaultPrompt == defaultPrompt)
}
