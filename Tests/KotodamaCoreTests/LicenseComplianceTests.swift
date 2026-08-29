import CryptoKit
import Foundation
import Testing

@Test func projectLicenseIsMITAndReadmeLinksIt() throws {
    let root = projectRoot()
    let licenseURL = root.appending(path: "LICENSE")
    guard FileManager.default.fileExists(atPath: licenseURL.path) else {
        Issue.record("repository LICENSE is missing")
        return
    }

    let projectLicense = try String(contentsOf: licenseURL, encoding: .utf8)
    #expect(projectLicense.contains("MIT License"))
    #expect(projectLicense.contains("Copyright (c) 2026 Makoto Tsuyuki"))

    let readme = try String(
        contentsOf: root.appending(path: "README.md"),
        encoding: .utf8
    )
    #expect(readme.contains("[MIT License](LICENSE)"))
}

@Test func repositoryLicenseMaterialsAreCompleteAndPinned() throws {
    let root = projectRoot()
    let licenseURL = root.appending(path: "LICENSE")
    let noticesURL = root.appending(path: "THIRD_PARTY_NOTICES.md")
    let manifestURL = root.appending(path: "Resources/ThirdPartyComponents.json")

    guard FileManager.default.fileExists(atPath: licenseURL.path) else {
        Issue.record("repository LICENSE is missing")
        return
    }
    guard FileManager.default.fileExists(atPath: noticesURL.path) else {
        Issue.record("THIRD_PARTY_NOTICES.md is missing")
        return
    }
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
        Issue.record("Resources/ThirdPartyComponents.json is missing")
        return
    }

    let projectLicense = try String(contentsOf: licenseURL, encoding: .utf8)
    #expect(projectLicense.contains("MIT License"))
    #expect(projectLicense.contains("Copyright (c) 2026 Makoto Tsuyuki"))

    let notices = try String(contentsOf: noticesURL, encoding: .utf8)
    let manifest = try JSONDecoder().decode(
        TestThirdPartyManifest.self,
        from: Data(contentsOf: manifestURL)
    )
    #expect(manifest.schemaVersion == 1)

    let expectedIDs: Set<String> = [
        "whisper.cpp",
        "llama.cpp",
        "openspec-skills",
        "openai-whisper-models",
        "gemma-4-e4b-it-qat-q4-0",
    ]
    #expect(Set(manifest.components.map(\.id)) == expectedIDs)

    for component in manifest.components {
        #expect(component.sourceURL.scheme == "https")
        #expect(!component.version.isEmpty)
        #expect(!component.licenseName.isEmpty)
        #expect(!component.scopes.isEmpty)
        #expect(notices.contains(component.displayName))

        let licenseFileURL = root.appending(path: component.licenseFile)
        guard FileManager.default.fileExists(atPath: licenseFileURL.path) else {
            Issue.record("license file is missing for \(component.id): \(component.licenseFile)")
            continue
        }
        let digest = SHA256.hash(data: try Data(contentsOf: licenseFileURL))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(digest == component.licenseSHA256)
    }

    try verifyRuntimeReferences(manifest, root: root)
    try verifyModelReferences(manifest, root: root)
    try verifyOpenSpecReference(manifest, root: root)
}

private struct TestThirdPartyManifest: Decodable {
    let schemaVersion: Int
    let components: [TestThirdPartyComponent]
}

private struct TestThirdPartyComponent: Decodable {
    let id: String
    let displayName: String
    let sourceURL: URL
    let version: String
    let licenseName: String
    let licenseFile: String
    let licenseSHA256: String
    let scopes: [String]
    let runtimeID: String?
    let modelIDs: [String]?
}

private struct TestRuntimeLock: Decodable {
    struct Entry: Decodable { let commit: String }
    let runtimes: [String: Entry]
}

private struct TestModelManifest: Decodable {
    struct Entry: Decodable {
        let id: String
        let revision: String
        let licenseName: String
    }
    let models: [Entry]
}

private func projectRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func verifyRuntimeReferences(
    _ manifest: TestThirdPartyManifest,
    root: URL
) throws {
    let lock = try JSONDecoder().decode(
        TestRuntimeLock.self,
        from: Data(contentsOf: root.appending(path: "Config/runtime-lock.json"))
    )
    let components = Dictionary(
        uniqueKeysWithValues: manifest.components.compactMap { component in
            component.runtimeID.map { ($0, component) }
        }
    )
    #expect(Set(components.keys) == Set(lock.runtimes.keys))
    for (runtimeID, entry) in lock.runtimes {
        #expect(components[runtimeID]?.version == entry.commit)
    }
}

private func verifyModelReferences(
    _ manifest: TestThirdPartyManifest,
    root: URL
) throws {
    let modelManifest = try JSONDecoder().decode(
        TestModelManifest.self,
        from: Data(contentsOf: root.appending(path: "Resources/Models.json"))
    )
    let componentByModelID = Dictionary(
        uniqueKeysWithValues: manifest.components.flatMap { component in
            (component.modelIDs ?? []).map { ($0, component) }
        }
    )
    #expect(Set(componentByModelID.keys) == Set(modelManifest.models.map(\.id)))
    for model in modelManifest.models {
        let component = componentByModelID[model.id]
        #expect(component?.version == model.revision)
        #expect(component?.licenseName == model.licenseName)
        #expect(component?.scopes.contains("modelCatalog") == true)
    }
}

private func verifyOpenSpecReference(
    _ manifest: TestThirdPartyManifest,
    root: URL
) throws {
    let component = manifest.components.first { $0.id == "openspec-skills" }
    #expect(component?.scopes == ["sourceRepository"])
    let skillRoot = root.appending(path: ".agents/skills")
    let skillFiles = try FileManager.default.contentsOfDirectory(
        at: skillRoot,
        includingPropertiesForKeys: [.isDirectoryKey]
    ).filter { url in
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }.map { $0.appending(path: "SKILL.md") }
    #expect(!skillFiles.isEmpty)
    for skillFile in skillFiles {
        let contents = try String(contentsOf: skillFile, encoding: .utf8)
        #expect(contents.contains("license: MIT"))
        #expect(contents.contains("generatedBy: \"\(component?.version ?? "")\""))
    }
}
