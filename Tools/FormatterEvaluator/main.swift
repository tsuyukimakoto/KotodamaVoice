import Darwin.Mach
import Foundation
import KotodamaCore

private struct EvaluationConfiguration: Decodable {
    let schemaVersion: Int
    let prompt: String
    let cases: [EvaluationCase]
}

private struct EvaluationCase: Decodable {
    let id: String
    let source: String
    let requiredTerms: [String]
    let fillers: [String]
}

private struct CaseResult: Encodable {
    let id: String
    let source: String
    let output: String
    let requiredTermMatches: Int
    let requiredTermTotal: Int
    let remainingFillers: Int
    let fillerTotal: Int
    let contentEditDistance: Int
    let contentInsertions: Int
    let contentDeletions: Int
    let contentSubstitutions: Int
    let sourceContentCharacterCount: Int
    let outputContentCharacterCount: Int
    let sourcePunctuationCount: Int
    let outputPunctuationCount: Int
    let promptTokenCount: Int
    let generatedTokenCount: Int
    let promptTokensPerSecond: Double
    let generationTokensPerSecond: Double
    let promptMilliseconds: Double
    let generationMilliseconds: Double
    let physicalFootprintBytes: UInt64
}

private struct EditCounts {
    let distance: Int
    let insertions: Int
    let deletions: Int
    let substitutions: Int
}

private struct EvaluationResult: Encodable {
    let model: String
    let runtimeRevision: String
    let loadMilliseconds: Double
    let baselinePhysicalFootprintBytes: UInt64
    let loadedPhysicalFootprintBytes: UInt64
    let cases: [CaseResult]
}

private enum EvaluationError: Error {
    case invalidArguments
    case invalidConfiguration
    case missingMetrics
    case cannotMeasureFootprint
}

private struct Arguments {
    let modelURL: URL
    let casesURL: URL
    let runtimeRevision: String

    init(_ values: [String]) throws {
        guard values.count == 4 else { throw EvaluationError.invalidArguments }
        modelURL = URL(fileURLWithPath: values[1])
        casesURL = URL(fileURLWithPath: values[2])
        runtimeRevision = values[3]
    }
}

private func physicalFootprint() throws -> UInt64 {
    var information = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size
            / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &information) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else {
        throw EvaluationError.cannotMeasureFootprint
    }
    return information.phys_footprint
}

private func elapsedMilliseconds(
    from start: ContinuousClock.Instant,
    to end: ContinuousClock.Instant
) -> Double {
    let components = start.duration(to: end).components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func canonical(_ text: String) -> String {
    text.precomposedStringWithCompatibilityMapping
        .folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "ja_JP")
        )
        .replacingOccurrences(of: "‑", with: "-")
        .replacingOccurrences(of: "–", with: "-")
        .replacingOccurrences(of: "—", with: "-")
}

private func contentCharacters(_ text: String) -> [Character] {
    Array(canonical(text).filter { character in
        character.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }
    })
}

private func editCounts(_ lhs: [Character], _ rhs: [Character]) -> EditCounts {
    var distances = Array(
        repeating: Array(repeating: 0, count: rhs.count + 1),
        count: lhs.count + 1
    )
    for leftIndex in 0...lhs.count {
        distances[leftIndex][0] = leftIndex
    }
    for rightIndex in 0...rhs.count {
        distances[0][rightIndex] = rightIndex
    }
    if !lhs.isEmpty, !rhs.isEmpty {
        for leftIndex in 1...lhs.count {
            for rightIndex in 1...rhs.count {
                distances[leftIndex][rightIndex] = min(
                    distances[leftIndex][rightIndex - 1] + 1,
                    distances[leftIndex - 1][rightIndex] + 1,
                    distances[leftIndex - 1][rightIndex - 1]
                        + (lhs[leftIndex - 1] == rhs[rightIndex - 1] ? 0 : 1)
                )
            }
        }
    }

    var leftIndex = lhs.count
    var rightIndex = rhs.count
    var insertions = 0
    var deletions = 0
    var substitutions = 0
    while leftIndex > 0 || rightIndex > 0 {
        if leftIndex > 0,
           rightIndex > 0,
           lhs[leftIndex - 1] == rhs[rightIndex - 1],
           distances[leftIndex][rightIndex] == distances[leftIndex - 1][rightIndex - 1]
        {
            leftIndex -= 1
            rightIndex -= 1
        } else if rightIndex > 0,
                  distances[leftIndex][rightIndex] == distances[leftIndex][rightIndex - 1] + 1
        {
            insertions += 1
            rightIndex -= 1
        } else if leftIndex > 0,
                  distances[leftIndex][rightIndex] == distances[leftIndex - 1][rightIndex] + 1
        {
            deletions += 1
            leftIndex -= 1
        } else {
            substitutions += 1
            leftIndex -= 1
            rightIndex -= 1
        }
    }
    return EditCounts(
        distance: distances[lhs.count][rhs.count],
        insertions: insertions,
        deletions: deletions,
        substitutions: substitutions
    )
}

private func punctuationCount(_ text: String) -> Int {
    text.count { "、。,.!?！？".contains($0) }
}

private func perSecond(count: Int, milliseconds: Double) -> Double {
    milliseconds > 0 ? Double(count) / (milliseconds / 1_000) : 0
}

private func evaluate() throws -> EvaluationResult {
    let arguments = try Arguments(CommandLine.arguments)
    let configuration = try JSONDecoder().decode(
        EvaluationConfiguration.self,
        from: Data(contentsOf: arguments.casesURL)
    )
    guard configuration.schemaVersion == 1,
          !configuration.prompt.isEmpty,
          !configuration.cases.isEmpty
    else {
        throw EvaluationError.invalidConfiguration
    }

    let backend = CLlamaBackend()
    let runtime = FormatterRuntime(
        backend: backend,
        resolveModelURL: { _ in arguments.modelURL }
    )
    let clock = ContinuousClock()
    let baselineFootprint = try physicalFootprint()
    let loadStart = clock.now
    try runtime.load(modelID: arguments.modelURL.deletingPathExtension().lastPathComponent)
    let loadEnd = clock.now
    let loadedFootprint = try physicalFootprint()
    defer { runtime.unload() }

    var results: [CaseResult] = []
    for evaluationCase in configuration.cases {
        let output = try runtime.format(
            text: evaluationCase.source,
            prompt: configuration.prompt,
            requestID: PipelineRequestID()
        )
        guard let metrics = backend.lastMetrics else {
            throw EvaluationError.missingMetrics
        }
        let sourceCharacters = contentCharacters(evaluationCase.source)
        let outputCharacters = contentCharacters(output)
        let edits = editCounts(sourceCharacters, outputCharacters)
        let normalizedOutput = canonical(output)
        results.append(
            CaseResult(
                id: evaluationCase.id,
                source: evaluationCase.source,
                output: output,
                requiredTermMatches: evaluationCase.requiredTerms.count {
                    normalizedOutput.contains(canonical($0))
                },
                requiredTermTotal: evaluationCase.requiredTerms.count,
                remainingFillers: evaluationCase.fillers.count {
                    normalizedOutput.contains(canonical($0))
                },
                fillerTotal: evaluationCase.fillers.count,
                contentEditDistance: edits.distance,
                contentInsertions: edits.insertions,
                contentDeletions: edits.deletions,
                contentSubstitutions: edits.substitutions,
                sourceContentCharacterCount: sourceCharacters.count,
                outputContentCharacterCount: outputCharacters.count,
                sourcePunctuationCount: punctuationCount(evaluationCase.source),
                outputPunctuationCount: punctuationCount(output),
                promptTokenCount: metrics.promptTokenCount,
                generatedTokenCount: metrics.generatedTokenCount,
                promptTokensPerSecond: perSecond(
                    count: metrics.promptTokenCount,
                    milliseconds: metrics.promptMilliseconds
                ),
                generationTokensPerSecond: perSecond(
                    count: metrics.generatedTokenCount,
                    milliseconds: metrics.generationMilliseconds
                ),
                promptMilliseconds: metrics.promptMilliseconds,
                generationMilliseconds: metrics.generationMilliseconds,
                physicalFootprintBytes: try physicalFootprint()
            )
        )
    }

    return EvaluationResult(
        model: arguments.modelURL.lastPathComponent,
        runtimeRevision: arguments.runtimeRevision,
        loadMilliseconds: elapsedMilliseconds(from: loadStart, to: loadEnd),
        baselinePhysicalFootprintBytes: baselineFootprint,
        loadedPhysicalFootprintBytes: loadedFootprint,
        cases: results
    )
}

do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(evaluate()))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("formatter evaluation failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
