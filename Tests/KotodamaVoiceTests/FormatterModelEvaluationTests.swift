import Foundation
import Testing

@Test func formatterEvaluationUsesPinnedRuntimeAndFixedCases() throws {
    let rootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let evaluation = try formatterEvaluationJSON(
        at: rootURL.appending(path: "Config/FormatterModelEvaluation.json")
    )
    let cases = try formatterEvaluationJSON(
        at: rootURL.appending(path: "Config/FormatterEvaluationCases.json")
    )
    let runtimeLock = try formatterEvaluationJSON(
        at: rootURL.appending(path: "Config/runtime-lock.json")
    )

    let environment = try #require(evaluation["environment"] as? [String: Any])
    let runtimes = try #require(runtimeLock["runtimes"] as? [String: [String: Any]])
    let llama = try #require(runtimes["llama"])
    #expect(environment["runtimeRevision"] as? String == llama["commit"] as? String)

    let evaluatedCases = try #require(evaluation["cases"] as? [[String: Any]])
    let configuredCases = try #require(cases["cases"] as? [[String: Any]])
    #expect(evaluatedCases.compactMap { $0["id"] as? String }
        == configuredCases.compactMap { $0["id"] as? String })

    let conclusion = try #require(evaluation["conclusion"] as? [String: Any])
    #expect(conclusion["qualityAcceptedOnEvaluationSet"] as? Bool == true)
    #expect(conclusion["selectedAsDefault"] as? Bool == false)
}

private func formatterEvaluationJSON(at url: URL) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return try #require(object as? [String: Any])
}
