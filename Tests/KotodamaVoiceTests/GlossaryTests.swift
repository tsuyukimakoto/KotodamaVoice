import Foundation
import KotodamaCore
import Testing

@testable import KotodamaVoice

@Test @MainActor
func glossaryPersistsValidEditsAndRejectsInvalidChanges() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(UserDefaults(suiteName: "com.tsuyukimakoto.tests.\(UUID())"))
    let store = GlossarySettingsStore(directory: root, defaults: defaults)
    #expect(!store.useForSpeech && !store.useForFormatting && !store.diagnosticsEnabled)
    let entry = GlossaryEntry(term: " KotodamaVoice ", reading: "ことだまぼいす")
    try store.save(entry)
    let revision = store.document.revision
    #expect(store.document.entries.first?.term == "KotodamaVoice")
    #expect(throws: GlossaryValidationError.self) {
        try store.save(GlossaryEntry(term: "KotodamaVoice"))
    }
    #expect(throws: GlossaryValidationError.self) { try store.save(GlossaryEntry(term: " \n ")) }
    #expect(throws: GlossaryValidationError.self) {
        try store.save(GlossaryEntry(term: String(repeating: "あ", count: 129)))
    }
    #expect(store.document.revision == revision)
    store.setSpeech(true)
    store.setFormatting(true)
    store.setDiagnostics(true)
    let restored = GlossarySettingsStore(directory: root, defaults: defaults)
    #expect(restored.document.entries.count == 1)
    #expect(restored.useForSpeech && restored.useForFormatting && restored.diagnosticsEnabled)
    #expect(restored.document.entries.first?.id == entry.id)
    try store.save(GlossaryEntry(id: entry.id, term: "Voice"))
    #expect(store.document.entries.first?.term == "Voice")
    try store.delete(entry.id)
    #expect(store.document.entries.isEmpty)
    let permissions = try FileManager.default.attributesOfItem(
        atPath: root.appending(path: "glossary.json").path)
    #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test @MainActor
func glossaryCorruptionAndWriteFailurePreserveFile() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "glossary.json")
    try Data("broken".utf8).write(to: file)
    let store = GlossarySettingsStore(directory: root, defaults: try isolatedGlossaryDefaults())
    #expect(store.errorMessage != nil)
    #expect(throws: (any Error).self) { try store.save(GlossaryEntry(term: "A")) }
    #expect(try Data(contentsOf: file) == Data("broken".utf8))
    let blocker = root.appending(path: "blocker")
    try Data().write(to: blocker)
    let blocked = GlossarySettingsStore(directory: blocker)
    #expect(throws: (any Error).self) { try blocked.save(GlossaryEntry(term: "B")) }
    #expect(blocked.document.entries.isEmpty)
}

@Test
func glossaryCountsAreLiteralNormalizedIndependentAndNonOverlapping() throws {
    let entries = ["Codex", "Voice", "KotodamaVoice", "é", "aa", "無し"].map {
        GlossaryEntry(term: $0)
    }
    let counts = GlossaryCounter.count(
        "Codex Codex codex Ｃｏｄｅｘ KotodamaVoice e\u{301} aaaa", entries: entries)
    #expect(counts.map(\.count) == [2, 1, 1, 1, 2, 0])
    #expect(throws: GlossaryValidationError.self) {
        try GlossaryDocument(entries: (0...200).map { GlossaryEntry(term: "T\($0)") }).validated()
    }
}

@Test
func glossaryPromptIsDataAndOffIsUnchanged() throws {
    let entry = GlossaryEntry(term: "Codex", reading: "こーでっくす", note: "開発ツール")
    #expect(try GlossaryPrompt.compose(base: "BASE", entries: []) == "BASE")
    let result = try GlossaryPrompt.compose(base: "BASE", entries: [entry])
    #expect(result.contains("Codex") && result.contains("こーでっくす") && result.contains("開発ツール"))
    #expect(result.contains("曖昧"))
}

@Test @MainActor
func glossarySnapshotFreezesSettingsAndClearsAtFinish() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = GlossarySettingsStore(directory: root, defaults: try isolatedGlossaryDefaults())
    try settings.save(GlossaryEntry(term: "Before"))
    let session = GlossarySession(
        settings: settings,
        diagnostics: GlossaryDiagnostics(directory: root.appending(path: "logs")))
    settings.setSpeech(true)
    session.begin()
    settings.setSpeech(false)
    try settings.save(GlossaryEntry(term: "After"))
    #expect(session.snapshot?.speech == true)
    #expect(session.snapshot?.document.entries.map(\.term) == ["Before"])
    session.finish()
    #expect(session.snapshot == nil)
}

@Test @MainActor
func speechWorkerSendsHintAndDecodesUsedIDs() async throws {
    let entry = GlossaryEntry(term: "Codex", reading: "こーでっくす")
    let worker = GlossaryTestWorker(entry: entry)
    let client = SpeechWorkerClient(worker: worker)
    let url = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let result = try await client.transcribe(
        modelID: "fixture",
        audioInput: WorkerAudioInput(
            fileHandle: handle, sampleRate: 16000, channelCount: 1, sampleCount: 1),
        requestID: PipelineRequestID(), hints: [SpeechGlossaryHint(entry: entry)])
    #expect(result.text == "Codex")
    #expect(result.submittedEntryIDs == [entry.id])
    let request = try #require(worker.lastRequest)
    let data = try NSKeyedArchiver.archivedData(
        withRootObject: WorkerRequest(
            requestID: request.requestID, operation: request.operation, options: request.options),
        requiringSecureCoding: true)
    let decoded = try #require(
        try NSKeyedUnarchiver.unarchivedObject(ofClass: WorkerRequest.self, from: data))
    #expect(decoded.options["glossary"]?.contains("Codex") == true)
}

@MainActor private final class GlossaryTestWorker: WorkerRequestPerforming {
    let entry: GlossaryEntry
    var lastRequest: WorkerRequest?
    init(entry: GlossaryEntry) { self.entry = entry }
    func perform(_ request: WorkerRequest, timeout: Duration) async throws -> WorkerReply {
        guard request.operation == .transcribe else {
            return WorkerReply(requestID: request.requestID)
        }
        lastRequest = request
        return WorkerReply(
            requestID: request.requestID,
            payload: try JSONEncoder().encode(
                SpeechGlossaryResult(text: "Codex", submittedEntryIDs: [entry.id])))
    }
}

@Test(arguments: [FormattingEngine.off, .builtIn, .external]) @MainActor
func glossaryFormattingRespectsEngineAndRecordsActualResult(engine: FormattingEngine) async throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = GlossarySettingsStore(directory: root, defaults: try isolatedGlossaryDefaults())
    try settings.save(GlossaryEntry(term: "Codex"))
    settings.setFormatting(true)
    settings.setDiagnostics(true)
    let session = GlossarySession(
        settings: settings,
        diagnostics: GlossaryDiagnostics(directory: root.appending(path: "logs")))
    session.begin()
    let id = PipelineRequestID()
    let coordinator = PipelineCoordinator(store: PipelineStore(initialState: .transcribing(id)))
    let formatter = GlossaryRecordingFormatter()
    let pipeline = TextFormattingPipeline(
        coordinator: coordinator, settings: FormatterSettingsStore(engine: engine),
        builtIn: formatter, external: formatter, glossary: session)
    let output = try await pipeline.process(LocalTranscription(requestID: id, text: "コーデックス"))
    #expect(output.text == (engine == .off ? "コーデックス" : "Codex"))
    #expect(formatter.entries.count == (engine == .off ? 0 : 1))
    let log = try String(contentsOf: #require(session.diagnostics.currentFile), encoding: .utf8)
    #expect(log.contains(engine == .off ? "\"counts\":null" : "\"count\":1"))
    #expect(session.snapshot == nil)
}

@MainActor private final class GlossaryRecordingFormatter: TextFormatting {
    var entries: [GlossaryEntry] = []
    func format(_ text: String, requestID: PipelineRequestID) async throws -> String { text }
    func format(_ text: String, requestID: PipelineRequestID, glossary: [GlossaryEntry])
        async throws -> String
    {
        entries = glossary
        return "Codex"
    }
}

@Test(arguments: [WorkerFailureCode.cancelled, .timedOut, .processingFailed, .capacityExceeded])
@MainActor
func glossaryFormattingFailuresRetainOriginalAndRecordReason(code: WorkerFailureCode) async throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = GlossarySettingsStore(directory: root, defaults: try isolatedGlossaryDefaults())
    try settings.save(GlossaryEntry(term: "Codex"))
    settings.setFormatting(true)
    settings.setDiagnostics(true)
    let session = GlossarySession(
        settings: settings,
        diagnostics: GlossaryDiagnostics(directory: root.appending(path: "logs")))
    session.begin()
    let id = PipelineRequestID()
    let formatter = GlossaryFailingFormatter(code: code)
    let pipeline = TextFormattingPipeline(
        coordinator: PipelineCoordinator(store: PipelineStore(initialState: .transcribing(id))),
        settings: FormatterSettingsStore(engine: .builtIn), builtIn: formatter, external: formatter,
        glossary: session)
    let result = try await pipeline.process(LocalTranscription(requestID: id, text: "BODY_CANARY"))
    #expect(result.text == "BODY_CANARY" && result.usedFallback)
    let text = try String(contentsOf: #require(session.diagnostics.currentFile), encoding: .utf8)
    #expect(!text.contains("BODY_CANARY"))
    #expect(text.contains("\"counts\":null"))
    if code == .timedOut { #expect(text.contains("timed_out")) }
    if code == .cancelled { #expect(text.contains("cancelled")) }
    if code == .capacityExceeded { #expect(text.contains("capacity_exceeded")) }
    #expect(!text.contains("\"effective\":\"applied\""))
}

@MainActor private final class GlossaryFailingFormatter: TextFormatting {
    let code: WorkerFailureCode
    init(code: WorkerFailureCode) { self.code = code }
    func format(_ text: String, requestID: PipelineRequestID) async throws -> String {
        throw FormatterWorkerClientError.workerFailure(code)
    }
    func format(_ text: String, requestID: PipelineRequestID, glossary: [GlossaryEntry])
        async throws -> String
    { throw FormatterWorkerClientError.workerFailure(code) }
}

@Test @MainActor
func glossaryConsentBelongsToExactEndpoint() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "com.tsuyukimakoto.GlossaryConsent.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = GlossarySettingsStore(directory: root, defaults: defaults)
    let first = try #require(URL(string: "https://www.tsuyukimakoto.com/v1/responses"))
    let second = try #require(URL(string: "https://www.tsuyukimakoto.com/other/responses"))
    #expect(!settings.permits(first))
    settings.approve(first)
    #expect(settings.permits(first) && !settings.permits(second))
    #expect(GlossarySettingsStore(directory: root, defaults: defaults).permits(first))
    #expect(settings.permits(URL(string: "http://127.0.0.1:1234/v1/responses")!))
}

@MainActor private func isolatedGlossaryDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "com.tsuyukimakoto.GlossaryTests.\(UUID())"))
}

@Test func glossaryRejectsUnicodeLineSeparators() throws {
    #expect(throws: GlossaryValidationError.self) {
        try GlossaryEntry(term: "A\u{2028}B").validated()
    }
}

@Test func glossaryCapacityFailureCrossesWorkerContract() {
    let service = WorkerService(runtime: CapacityFailureRuntime())
    service.perform(
        WorkerRequest(requestID: PipelineRequestID(), operation: .loadModel, modelID: "fixture")
    ) { reply in
        #expect(reply.failure == nil)
    }
    service.perform(
        WorkerRequest(
            requestID: PipelineRequestID(), operation: .format,
            options: ["text": "TEXT", "prompt": "PROMPT"])
    ) { reply in
        #expect(reply.failure?.code == .capacityExceeded)
        #expect(reply.payload == nil)
    }
}

private final class CapacityFailureRuntime: TextFormattingRuntime {
    func load(modelID: String) throws {}
    func cancel(requestID: PipelineRequestID) {}
    func cancelAll() {}
    func unload() {}
    func format(text: String, prompt: String, requestID: PipelineRequestID) throws -> String {
        throw WorkerRuntimeError.capacityExceeded
    }
}

@Test func glossaryPromptUsesStableReferenceSerialization() throws {
    let entries = [GlossaryEntry(term: "Term", reading: "reading", note: "description")]
    let prompts = try (0..<30).map { _ in try GlossaryPrompt.compose(base: "BASE", entries: entries)
    }
    #expect(Set(prompts).count == 1)
    #expect(
        prompts[0].contains(#"{"description":"description","reading":"reading","term":"Term"}"#))
}
