import AVFoundation
import Darwin.Mach
import Foundation
import KotodamaCore

private struct EvaluationResult: Encodable {
    let model: String
    let referenceCharacterCount: Int
    let recognizedCharacterCount: Int
    let editDistance: Int
    let characterErrorRate: Double
    let properNounMatches: Int
    let properNounTotal: Int
    let alphanumericMatches: Int
    let alphanumericTotal: Int
    let dateMatches: Int
    let dateTotal: Int
    let punctuationMatches: Int
    let punctuationTotal: Int
    let loadMilliseconds: Double
    let transcriptionMilliseconds: Double
    let baselinePhysicalFootprintBytes: UInt64
    let loadedPhysicalFootprintBytes: UInt64
    let transcribedPhysicalFootprintBytes: UInt64
}

private enum EvaluationError: Error {
    case invalidArguments
    case invalidAudio
    case cannotMeasureFootprint
}

private final class ConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !wasSupplied else {
            status.pointee = .endOfStream
            return nil
        }
        wasSupplied = true
        status.pointee = .haveData
        return buffer
    }
}

private struct Arguments {
    let modelURL: URL
    let audioURL: URL
    let referenceURL: URL

    init(_ values: [String]) throws {
        guard values.count == 4 else { throw EvaluationError.invalidArguments }
        modelURL = URL(fileURLWithPath: values[1])
        audioURL = URL(fileURLWithPath: values[2])
        referenceURL = URL(fileURLWithPath: values[3])
    }
}

private final class AudioFixture {
    let input: WorkerAudioInput
    private let fileURL: URL

    init(audioURL: URL) throws {
        let samples = try Self.convertToMono16KFloat(audioURL)
        guard !samples.isEmpty else { throw EvaluationError.invalidAudio }
        let temporaryURL = FileManager.default.temporaryDirectory.appending(
            path: "KotodamaSpeechEvaluation-\(UUID().uuidString).f32"
        )
        try samples.withUnsafeBytes { bytes in
            try Data(bytes).write(to: temporaryURL, options: .atomic)
        }
        fileURL = temporaryURL
        input = WorkerAudioInput(
            fileHandle: try FileHandle(forReadingFrom: temporaryURL),
            sampleRate: 16_000,
            channelCount: 1,
            sampleCount: Int64(samples.count)
        )
    }

    deinit {
        try? input.fileHandle.close()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func convertToMono16KFloat(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw EvaluationError.invalidAudio
        }
        try file.read(into: sourceBuffer)
        guard let destinationFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(
            from: sourceFormat,
            to: destinationFormat
        ) else {
            throw EvaluationError.invalidAudio
        }
        let ratio = destinationFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * ratio) + 32
        )
        guard let destinationBuffer = AVAudioPCMBuffer(
            pcmFormat: destinationFormat,
            frameCapacity: capacity
        ) else {
            throw EvaluationError.invalidAudio
        }
        let converterInput = ConverterInput(buffer: sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(
            to: destinationBuffer,
            error: &conversionError
        ) { _, inputStatus in
            converterInput.next(status: inputStatus)
        }
        guard conversionError == nil,
              status == .haveData || status == .endOfStream,
              let channel = destinationBuffer.floatChannelData?[0]
        else {
            throw conversionError ?? EvaluationError.invalidAudio
        }
        return Array(
            UnsafeBufferPointer(
                start: channel,
                count: Int(destinationBuffer.frameLength)
            )
        )
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
    let duration = start.duration(to: end)
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func canonical(_ text: String) -> String {
    let folded = text.precomposedStringWithCompatibilityMapping
        .folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "ja_JP")
        )
        .replacingOccurrences(of: "‑", with: "-")
        .replacingOccurrences(of: "–", with: "-")
        .replacingOccurrences(of: "—", with: "-")
    return String(folded.unicodeScalars.filter {
        !CharacterSet.whitespacesAndNewlines.contains($0)
    })
}

private func contentCharacters(_ text: String) -> [Character] {
    Array(canonical(text).filter { character in
        character.unicodeScalars.allSatisfy {
            !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }
    })
}

private func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
    var previous = Array(0...rhs.count)
    for (leftIndex, left) in lhs.enumerated() {
        var current = Array(repeating: 0, count: rhs.count + 1)
        current[0] = leftIndex + 1
        for (rightIndex, right) in rhs.enumerated() {
            current[rightIndex + 1] = min(
                current[rightIndex] + 1,
                previous[rightIndex + 1] + 1,
                previous[rightIndex] + (left == right ? 0 : 1)
            )
        }
        previous = current
    }
    return previous[rhs.count]
}

private func tokenMatches(_ tokens: [String], in text: String) -> Int {
    let normalized = canonical(text)
    return tokens.count { normalized.contains(canonical($0)) }
}

private func punctuationMatches(reference: String, recognized: String) -> Int {
    let expected = reference.filter { "、。,.!?！？".contains($0) }
    let actual = recognized.filter { "、。,.!?！？".contains($0) }
    let distance = editDistance(Array(expected), Array(actual))
    return max(0, expected.count - distance)
}

private func evaluate() throws -> EvaluationResult {
    let arguments = try Arguments(CommandLine.arguments)
    let reference = try String(contentsOf: arguments.referenceURL, encoding: .utf8)
    let audio = try AudioFixture(audioURL: arguments.audioURL)
    let runtime = SpeechRuntime(
        resolveModelURL: { _ in arguments.modelURL },
        language: "ja"
    )
    let clock = ContinuousClock()
    let baselineFootprint = try physicalFootprint()
    let loadStart = clock.now
    try runtime.load(modelID: arguments.modelURL.deletingPathExtension().lastPathComponent)
    let loadEnd = clock.now
    let loadedFootprint = try physicalFootprint()
    defer { runtime.unload() }

    let transcriptionStart = clock.now
    let recognized = try runtime.transcribe(
        audioInput: audio.input,
        requestID: PipelineRequestID()
    )
    let transcriptionEnd = clock.now
    let transcribedFootprint = try physicalFootprint()

    let referenceCharacters = contentCharacters(reference)
    let recognizedCharacters = contentCharacters(recognized)
    let edits = editDistance(referenceCharacters, recognizedCharacters)
    let properNouns = ["OpenAI", "ChatGPT", "Apple", "Xcode", "KotodamaVoice"]
    let alphanumeric = ["Wi-Fi 6E", "SSID", "KV-Test-2026"]
    let dates = ["2026年9月15日火曜日", "午後3時30分"]
    let punctuationTotal = reference.filter { "、。,.!?！？".contains($0) }.count

    return EvaluationResult(
        model: arguments.modelURL.lastPathComponent,
        referenceCharacterCount: referenceCharacters.count,
        recognizedCharacterCount: recognizedCharacters.count,
        editDistance: edits,
        characterErrorRate: referenceCharacters.isEmpty
            ? 0
            : Double(edits) / Double(referenceCharacters.count),
        properNounMatches: tokenMatches(properNouns, in: recognized),
        properNounTotal: properNouns.count,
        alphanumericMatches: tokenMatches(alphanumeric, in: recognized),
        alphanumericTotal: alphanumeric.count,
        dateMatches: tokenMatches(dates, in: recognized),
        dateTotal: dates.count,
        punctuationMatches: punctuationMatches(
            reference: reference,
            recognized: recognized
        ),
        punctuationTotal: punctuationTotal,
        loadMilliseconds: elapsedMilliseconds(from: loadStart, to: loadEnd),
        transcriptionMilliseconds: elapsedMilliseconds(
            from: transcriptionStart,
            to: transcriptionEnd
        ),
        baselinePhysicalFootprintBytes: baselineFootprint,
        loadedPhysicalFootprintBytes: loadedFootprint,
        transcribedPhysicalFootprintBytes: transcribedFootprint
    )
}

do {
    let result = try evaluate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(result))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("speech evaluation failed\n".utf8))
    exit(EXIT_FAILURE)
}
