import Foundation
import KotodamaCore
import Testing

@testable import KotodamaVoice

@Test @MainActor
func glossaryDiagnosticsCountsStagesAndDoesNotRecordContent() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = GlossaryDiagnostics(directory: root)
    #expect(logger.generation == nil)
    logger.setEnabled(true)
    let generation = try #require(logger.generation)
    let doc = GlossaryDocument(entries: [
        GlossaryEntry(term: "Codex", reading: "READING_CANARY", note: "NOTE_CANARY")
    ])
    let context = GlossarySnapshot(
        document: doc, speech: false, formatting: false, generation: generation)
    let id = PipelineRequestID()
    logger.record(
        context.event(
            requestID: id, stage: .speech, status: .success, text: "BODY_CANARY Codex",
            effective: .disabled), generation: generation)
    logger.record(
        context.event(
            requestID: id, stage: .formatting, status: .fallback, text: nil, effective: .disabled),
        generation: generation)
    let file = try #require(logger.currentFile)
    let data = try String(contentsOf: file, encoding: .utf8)
    #expect(data.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 2)
    #expect(data.contains("Codex") && data.contains("\"count\":1"))
    #expect(data.contains("\"counts\":null"))
    #expect(
        !data.contains("BODY_CANARY") && !data.contains("READING_CANARY")
            && !data.contains("NOTE_CANARY"))
    logger.setEnabled(false)
    logger.record(
        context.event(
            requestID: id, stage: .speech, status: .success, text: "Codex", effective: .disabled),
        generation: generation)
    #expect(try String(contentsOf: file, encoding: .utf8) == data)
    logger.setEnabled(true)
    #expect(logger.currentFile != file)
    logger.record(
        context.event(
            requestID: id, stage: .speech, status: .success, text: "Codex", effective: .disabled),
        generation: generation)
    #expect(try Data(contentsOf: #require(logger.currentFile)).isEmpty)
}

@Test @MainActor
func glossaryDiagnosticFailuresAndLimitsDoNotThrowIntoPipeline() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = GlossaryDiagnostics(directory: root, fileLimit: 1, totalLimit: 1)
    logger.setEnabled(true)
    let context = GlossarySnapshot(
        document: GlossaryDocument(), speech: false, formatting: false,
        generation: logger.generation)
    logger.record(
        context.event(
            requestID: PipelineRequestID(), stage: .speech, status: .failed, text: nil,
            effective: .notRun), generation: context.generation)
    #expect(logger.errorMessage != nil)
    #expect(logger.generation == nil)
    let link = root.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    let unsafe = GlossaryDiagnostics(directory: link)
    unsafe.setEnabled(true)
    #expect(unsafe.errorMessage != nil && unsafe.generation == nil)
}

@Test
func speechHintsKeepWholeEntriesAndSkipOversizedOnes() throws {
    let entries = [
        GlossaryEntry(term: "AA"), GlossaryEntry(term: "TOOLONG"), GlossaryEntry(term: "B"),
    ]
    let selected = SpeechHintSelection.select(
        entries.map(SpeechGlossaryHint.init), budget: 4, tokenCount: { $0.count })
    #expect(selected.prompt == "AA、B")
    #expect(selected.entryIDs == [entries[0].id, entries[2].id])
}

@Test @MainActor
func glossaryDiagnosticsRotatesAndSessionRecordsEachStageOnlyOnce() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try #require(
        UserDefaults(suiteName: "com.tsuyukimakoto.GlossaryRotation.\(UUID())"))
    let settings = GlossarySettingsStore(directory: root, defaults: defaults)
    try settings.save(GlossaryEntry(term: "Zero"))
    settings.setSpeech(false)
    settings.setFormatting(false)
    settings.setDiagnostics(true)
    let logger = GlossaryDiagnostics(
        directory: root.appending(path: "logs"), fileLimit: 650, totalLimit: 20_000)
    let session = GlossarySession(settings: settings, diagnostics: logger)
    session.begin()
    let first = try #require(logger.currentFile)
    let id = PipelineRequestID()
    session.record(
        requestID: id, stage: .speech, status: .success, text: "no match", effective: .disabled)
    let original = try Data(contentsOf: first)
    session.record(
        requestID: id, stage: .speech, status: .success, text: "Zero", effective: .disabled)
    #expect(try Data(contentsOf: first) == original)
    #expect(String(decoding: original, as: UTF8.self).contains("\"count\":0"))
    session.record(
        requestID: id, stage: .formatting, status: .skipped, text: nil, effective: .formatterOff)
    #expect(logger.currentFile != first)
    #expect(logger.generation != nil)
    let attributes = try FileManager.default.attributesOfItem(
        atPath: #require(logger.currentFile).path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let denied = GlossaryDiagnostics(directory: first)
    denied.setEnabled(true)
    #expect(denied.errorMessage != nil)
}

@Test
func speechHintsExcludeReadingsAndPreserveCanonicalPunctuation() throws {
    let entries = [
        GlossaryEntry(term: "Vroma Studio Track", reading: "ブロマ スタジオ トラック", note: "音声作品の制作アプリ"),
        GlossaryEntry(term: "Tool (Pro)", reading: "つーるぷろ"),
    ]
    let hints = entries.map(SpeechGlossaryHint.init)
    let selected = SpeechHintSelection.select(hints, budget: 100, tokenCount: { $0.count })
    #expect(selected.prompt == "Vroma Studio Track、Tool (Pro)")
    #expect(selected.entryIDs == entries.map(\.id))
    let wire = String(decoding: try JSONEncoder().encode(hints), as: UTF8.self)
    #expect(!wire.contains("reading") && !wire.contains("ブロマ"))
    let formatterPrompt = try GlossaryPrompt.compose(base: "BASE", entries: entries)
    #expect(formatterPrompt.contains("ブロマ スタジオ トラック"))
    #expect(formatterPrompt.contains("音声作品の制作アプリ"))
}
