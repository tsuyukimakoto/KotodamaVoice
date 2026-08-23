import Foundation
import Testing
@testable import KotodamaCore

@Test func modelManifestAcceptsCompletePinnedEntry() throws {
    let manifest = try ModelManifestLoader.decode(
        manifestData(entries: [validModelEntry()])
    )

    #expect(manifest.schemaVersion == 1)
    #expect(manifest.models.count == 1)
    #expect(manifest.models[0].isDefault)
    #expect(manifest.models[0].revision == String(repeating: "0", count: 40))
    #expect(manifest.models[0].byteCount == 1_024)
}

@Test func modelManifestRejectsMultipleDefaultsForOnePurpose() {
    var first = validModelEntry()
    first["id"] = "speech-a"
    first["fileName"] = "speech-a.bin"
    var second = validModelEntry()
    second["id"] = "speech-b"
    second["fileName"] = "speech-b.bin"

    #expect(throws: ModelManifestError.multipleDefaults(.speech)) {
        try ModelManifestLoader.decode(manifestData(entries: [first, second]))
    }
}

@Test func modelManifestRejectsMissingRequiredField() {
    var entry = validModelEntry()
    entry.removeValue(forKey: "licenseURL")

    #expect(throws: ModelManifestError.decoding) {
        try ModelManifestLoader.decode(manifestData(entries: [entry]))
    }
}

@Test func modelManifestRejectsDuplicateID() {
    let entry = validModelEntry()

    #expect(throws: ModelManifestError.duplicateID("speech-fixture")) {
        try ModelManifestLoader.decode(manifestData(entries: [entry, entry]))
    }
}

@Test func modelManifestRejectsExecutableFileType() {
    var entry = validModelEntry()
    entry["fileName"] = "payload.dylib"

    #expect(throws: ModelManifestError.disallowedFileType("payload.dylib")) {
        try ModelManifestLoader.decode(manifestData(entries: [entry]))
    }
}

@Test func modelManifestRejectsMalformedSHA256() {
    var entry = validModelEntry()
    entry["sha256"] = "not-a-sha256"

    #expect(throws: ModelManifestError.invalidSHA256("speech-fixture")) {
        try ModelManifestLoader.decode(manifestData(entries: [entry]))
    }
}

private func validModelEntry() -> [String: Any] {
    [
        "id": "speech-fixture",
        "displayName": "Speech Fixture",
        "purpose": "speech",
        "version": "1.0.0",
        "sourceURL": "https://example.invalid/models/speech.bin",
        "revision": String(repeating: "0", count: 40),
        "fileName": "speech.bin",
        "byteCount": 1_024,
        "sha256": String(repeating: "a", count: 64),
        "licenseName": "MIT",
        "licenseURL": "https://example.invalid/licenses/mit",
        "runtime": "whisper",
        "isDefault": true,
    ]
}

private func manifestData(entries: [[String: Any]]) -> Data {
    try! JSONSerialization.data(
        withJSONObject: ["schemaVersion": 1, "models": entries],
        options: [.sortedKeys]
    )
}
