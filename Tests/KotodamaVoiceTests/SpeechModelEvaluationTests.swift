import Foundation
import Testing

@Test func speechEvaluationMatchesPinnedDefaultManifest() throws {
    let rootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let evaluation = try decodeJSON(
        at: rootURL.appending(path: "Config/SpeechModelEvaluation.json")
    )
    let manifest = try decodeJSON(
        at: rootURL.appending(path: "Resources/Models.json")
    )
    let runtimeLock = try decodeJSON(
        at: rootURL.appending(path: "Config/runtime-lock.json")
    )

    let defaultID = try #require(
        evaluation["selectedDefaultModelID"] as? String
    )
    let models = try #require(manifest["models"] as? [[String: Any]])
    let defaultModel = try #require(models.first {
        $0["id"] as? String == defaultID && $0["isDefault"] as? Bool == true
    })
    let results = try #require(evaluation["results"] as? [[String: Any]])
    let defaultResult = try #require(results.first {
        $0["modelID"] as? String == defaultID
    })
    let environment = try #require(
        evaluation["environment"] as? [String: Any]
    )
    let runtimes = try #require(
        runtimeLock["runtimes"] as? [String: [String: Any]]
    )
    let whisper = try #require(runtimes["whisper"])

    #expect(defaultResult["fileByteCount"] as? Int == defaultModel["byteCount"] as? Int)
    #expect(defaultResult["fileSHA256"] as? String == defaultModel["sha256"] as? String)
    #expect(environment["runtimeRevision"] as? String == whisper["commit"] as? String)
}

private func decodeJSON(at url: URL) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return try #require(object as? [String: Any])
}
