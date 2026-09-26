import AVFoundation
import Foundation
import KotodamaCore
import Testing

@testable import KotodamaVoice

@Suite(.serialized) @MainActor
struct GlossaryOfflineEvaluationTests {
    @Test func fixedAudioAcrossFourGlossaryModes() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["KOTODAMA_GLOSSARY_EVALUATION"],
            !rootPath.isEmpty, !rootPath.hasPrefix("$(")
        else { return }
        let root = URL(fileURLWithPath: rootPath)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let models = ModelCatalog().models
        let speechModel = try #require(models.first { $0.purpose == .speech && $0.isDefault })
        let formatterModel = try #require(models.first { $0.purpose == .formatter })
        let speechCopy = try install(
            repository.appending(path: ".build/speech-evaluation/models/\(speechModel.fileName)"),
            model: speechModel)
        let formatterCopy = try install(
            repository.appending(path: ".build/test-fixtures/\(formatterModel.fileName)"),
            model: formatterModel)
        let speech = SpeechWorkerClient()
        let formatter = FormatterWorkerClient(
            modelID: { formatterModel.id }, prompt: { "入力の意味、数値を保ち、句読点を整えた本文だけを返してください。" })
        let suite = "com.tsuyukimakoto.GlossaryEvaluation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let working = URL(fileURLWithPath: "/private/tmp").appending(
            path: "GlossaryEvaluation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: working) }
        let settings = GlossarySettingsStore(directory: working, defaults: defaults)
        try settings.save(GlossaryEntry(term: "KotodamaVoice", reading: "ことだまぼいす", note: "音声入力アプリ"))
        try settings.save(GlossaryEntry(term: "箸", reading: "はし", note: "食事に使う道具。川に架かる橋とは別の語。"))
        settings.setDiagnostics(true)
        let session = GlossarySession(
            settings: settings,
            diagnostics: GlossaryDiagnostics(directory: working.appending(path: "logs")))
        struct Row: Encodable {
            let fixture: String
            let speech: Bool
            let formatting: Bool
            let speechCounts: [GlossaryCount]
            let outputCounts: [GlossaryCount]
            let elapsedSeconds: Double
            let speechRSSKB: Int
            let formatterRSSKB: Int
        }
        var rows: [Row] = []
        do {
            for name in ["term", "homophone", "plain"] {
                let buffer = try audio(root.appending(path: "\(name).caf"))
                for useSpeech in [false, true] {
                    for useFormatting in [false, true] {
                        settings.setSpeech(useSpeech)
                        settings.setFormatting(useFormatting)
                        let store = PipelineStore(initialState: .recording)
                        let coordinator = PipelineCoordinator(store: store)
                        let pipeline = LocalSpeechPipeline(
                            store: store, coordinator: coordinator,
                            recorder: EvaluationRecorder(buffer: buffer),
                            temporaryAudioStore: TemporaryAudioStore(
                                rootURL: working.appending(path: "audio")), speech: speech,
                            glossary: session)
                        let formatting = TextFormattingPipeline(
                            coordinator: coordinator,
                            settings: FormatterSettingsStore(engine: .builtIn),
                            builtIn: formatter, external: UnavailableTextFormatter(),
                            glossary: session, modelIdentifier: { _ in formatterModel.id })
                        try pipeline.startRecording()
                        let start = Date()
                        let transcript = try await pipeline.stopAndTranscribe(
                            modelID: speechModel.id)
                        let output = try await formatting.process(transcript)
                        #expect(!output.usedFallback)
                        let speechCounts = GlossaryCounter.count(
                            transcript.text, entries: settings.document.entries)
                        let outputCounts = GlossaryCounter.count(
                            output.text, entries: settings.document.entries)
                        rows.append(
                            Row(
                                fixture: name, speech: useSpeech, formatting: useFormatting,
                                speechCounts: speechCounts, outputCounts: outputCounts,
                                elapsedSeconds: Date().timeIntervalSince(start),
                                speechRSSKB: try await rss(.speech),
                                formatterRSSKB: try await rss(.formatter)))
                        if name == "term" { #expect(output.text.contains("123")) }
                        if name == "homophone" {
                            #expect(output.text.contains("橋"), "Synthetic fixture: \(output.text)")
                            if useFormatting {
                                #expect(
                                    output.text.contains("箸"), "Synthetic fixture: \(output.text)")
                            }
                        }
                        if name == "plain" {
                            #expect(output.text.contains("3"))
                            #expect(outputCounts.allSatisfy { $0.count == 0 })
                        }
                        let logURL = try #require(session.diagnostics.currentFile)
                        let lines = try String(contentsOf: logURL, encoding: .utf8).split(
                            separator: "\n")
                        let pair = try lines.suffix(2).map {
                            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
                        }
                        #expect(
                            pair.count == 2
                                && pair.allSatisfy {
                                    $0["requestID"] as? String
                                        == transcript.requestID.rawValue.uuidString
                                })
                        if useSpeech {
                            #expect(
                                Set(pair[0]["submittedEntryIDs"] as? [String] ?? [])
                                    == Set(settings.document.entries.map { $0.id.uuidString }))
                        }
                        let loggedCounts = pair.compactMap { $0["counts"] as? [[String: Any]] }.map
                        { $0.compactMap { $0["count"] as? Int } }
                        #expect(
                            loggedCounts == [speechCounts.map(\.count), outputCounts.map(\.count)])
                    }
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(
                to: root.appending(path: "results.json"), options: .atomic)
            let termRows = rows.filter { $0.fixture == "term" }
            let baseline = try #require(termRows.first { !$0.speech && !$0.formatting })
                .outputCounts[0].count
            #expect(
                termRows.contains {
                    ($0.speech || $0.formatting) && $0.outputCounts[0].count > baseline
                })
            try await speech.unload()
            try await formatter.unloadForDeletion(modelID: formatterModel.id)
        } catch {
            try? await speech.unload()
            try? await formatter.unloadForDeletion(modelID: formatterModel.id)
            throw error
        }
        if let speechCopy { try FileManager.default.removeItem(at: speechCopy) }
        if let formatterCopy { try FileManager.default.removeItem(at: formatterCopy) }
    }

    @Test func speechOnlyDoesNotAppendGlossaryReading() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["KOTODAMA_GLOSSARY_EVALUATION"],
            !rootPath.isEmpty, !rootPath.hasPrefix("$(")
        else { return }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let model = try #require(
            ModelCatalog().models.first { $0.purpose == .speech && $0.isDefault })
        let ownedCopy = try install(
            repository.appending(path: ".build/speech-evaluation/models/\(model.fileName)"),
            model: model)
        let speech = SpeechWorkerClient()
        let entry = GlossaryEntry(term: "Vroma Studio Track", reading: "ブロマ スタジオ トラック")
        let root = URL(fileURLWithPath: rootPath)
        let buffer = try audio(root.appending(path: "vroma.caf"))
        let temporary = TemporaryAudioStore()
        do {
            let id = PipelineRequestID()
            let lease = try temporary.createLease(requestID: id, buffer: buffer)
            defer { lease.release() }
            let result = try await speech.transcribe(
                modelID: model.id, audioInput: lease.audioInput, requestID: id,
                hints: [SpeechGlossaryHint(entry: entry)])
            #expect(result.submittedEntryIDs == [entry.id])
            #expect(result.text.contains(entry.term), "Synthetic fixture: \(result.text)")
            #expect(
                !result.text.contains("（") && !result.text.contains("）"),
                "Synthetic fixture: \(result.text)")
            #expect(
                !result.text.contains("ブロマ") && !result.text.contains("トラック"),
                "Synthetic fixture: \(result.text)")
            try await speech.unload()
        } catch {
            try? await speech.unload()
            throw error
        }
        if let ownedCopy { try FileManager.default.removeItem(at: ownedCopy) }
    }

    private func install(_ source: URL, model: ModelManifestEntry) throws -> URL? {
        let storage = FoundationModelStorage()
        #expect(try storage.fileSize(at: source) == model.byteCount)
        let hash = try storage.sha256(at: source)
        guard hash == model.sha256 else { throw WorkerRuntimeError.invalidInput }
        let group = try #require(
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.tsuyukimakoto.KotodamaVoice"))
        let directory = group.appending(path: "Models/\(model.id)")
        let destination = directory.appending(path: model.fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            #expect(try storage.sha256(at: destination) == model.sha256)
            return nil
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        return directory
    }

    private func audio(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return buffer
    }
    private func rss(_ endpoint: WorkerEndpoint) async throws -> Int {
        let reply = try await WorkerDiagnosticClient().echo(endpoint)
        let payload = try #require(reply.payload)
        let pid = try JSONDecoder().decode(WorkerProcessSnapshot.self, from: payload)
            .processIdentifier
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", String(pid)]
        process.standardOutput = pipe
        try process.run()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return Int(
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            ?? 0
    }
}

@MainActor private final class EvaluationRecorder: AudioRecordingManaging {
    let buffer: AVAudioPCMBuffer
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func start() throws {}
    func stop() throws -> AVAudioPCMBuffer { buffer }
    func cancel() {}
}
