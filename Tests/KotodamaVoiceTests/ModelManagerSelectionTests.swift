import Foundation
import KotodamaCore
import Testing
@testable import KotodamaVoice

@Test @MainActor
func modelManagerRestoresOnlyInstalledSelection() throws {
    let fixture = try ModelManagerFixture()
    let speech = fixture.model(id: "speech-a", purpose: .speech)
    try fixture.installFile(for: speech)
    fixture.defaults.set(speech.id, forKey: "selectedModel.speech")

    let manager = ModelManager(
        models: [speech],
        rootURL: fixture.rootURL,
        fileManager: fixture.fileManager,
        defaults: fixture.defaults
    )

    #expect(manager.selectedModel(for: .speech)?.id == speech.id)
}

@Test @MainActor
func modelManagerRejectsSelectionBeforeInstallation() throws {
    let fixture = try ModelManagerFixture()
    let speech = fixture.model(id: "speech-a", purpose: .speech)
    let manager = ModelManager(
        models: [speech],
        rootURL: fixture.rootURL,
        fileManager: fixture.fileManager,
        defaults: fixture.defaults
    )

    #expect(throws: ModelSelectionError.notInstalled) {
        try manager.select(speech)
    }
    #expect(manager.selectedModel(for: .speech) == nil)
}

@Test @MainActor
func modelManagerKeepsExplicitSelectionAcrossRecreation() throws {
    let fixture = try ModelManagerFixture()
    let first = fixture.model(id: "speech-a", purpose: .speech)
    let second = fixture.model(id: "speech-b", purpose: .speech)
    try fixture.installFile(for: first)
    try fixture.installFile(for: second)
    var manager: ModelManager? = ModelManager(
        models: [first, second],
        rootURL: fixture.rootURL,
        fileManager: fixture.fileManager,
        defaults: fixture.defaults
    )
    try manager?.select(second)
    manager = nil

    let restored = ModelManager(
        models: [first, second],
        rootURL: fixture.rootURL,
        fileManager: fixture.fileManager,
        defaults: fixture.defaults
    )

    #expect(restored.selectedModel(for: .speech)?.id == second.id)
}

private final class ModelManagerFixture {
    let fileManager = FileManager.default
    let rootURL: URL
    let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        rootURL = fileManager.temporaryDirectory.appending(
            path: "ModelManagerSelectionTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        suiteName = "jp.tsuyuki.ModelManagerSelectionTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        try? fileManager.removeItem(at: rootURL)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func model(id: String, purpose: ModelPurpose) -> ModelManifestEntry {
        ModelManifestEntry(
            id: id,
            displayName: id,
            purpose: purpose,
            version: "1",
            sourceURL: URL(string: "https://example.com/\(id).bin")!,
            revision: String(repeating: "a", count: 40),
            fileName: "\(id).bin",
            byteCount: 1,
            sha256: String(repeating: "b", count: 64),
            licenseName: "MIT",
            licenseURL: URL(string: "https://example.com/license")!,
            runtime: .whisper
        )
    }

    func installFile(for model: ModelManifestEntry) throws {
        let directory = rootURL.appending(
            path: model.id,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data([0]).write(to: directory.appending(path: model.fileName))
    }

}
