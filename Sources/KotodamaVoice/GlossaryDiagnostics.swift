import AppKit
import Darwin
import Foundation
import KotodamaCore
import Observation

struct GlossarySnapshot: Sendable {
    let document: GlossaryDocument
    let speech: Bool
    let formatting: Bool
    let generation: UUID?

    func event(
        requestID: PipelineRequestID, stage: GlossaryStage, status: GlossaryStageStatus,
        text: String?, effective: GlossaryEffective, engine: String = "unknown",
        modelID: String? = nil,
        submitted: [UUID] = [], reason: GlossaryFailureReason? = nil
    ) -> GlossaryDiagnosticEvent {
        GlossaryDiagnosticEvent(
            timestamp: Date(), requestID: requestID.rawValue, glossaryRevision: document.revision,
            stage: stage, status: status, engine: engine, modelID: modelID,
            requested: .init(speech: speech, formatting: formatting), effective: effective,
            submittedEntryIDs: submitted,
            omittedEntryCount: effective == .applied ? document.entries.count - submitted.count : 0,
            counts: text.map { GlossaryCounter.count($0, entries: document.entries) },
            reason: reason)
    }
}

enum GlossaryStage: String, Codable, Hashable { case speech, formatting }
enum GlossaryStageStatus: String, Codable {
    case success, skipped, fallback, cancelled, failed
    case notRun = "not_run"
}
enum GlossaryEffective: String, Codable {
    case applied, disabled, empty, unsupported, unknown
    case formatterOff = "formatter_off"
    case consentMissing = "consent_missing"
    case notRun = "not_run"
}
enum GlossaryFailureReason: String, Codable {
    case processingFailed = "processing_failed"
    case invalidOutput = "invalid_output"
    case capacityExceeded = "capacity_exceeded"
    case cancelled
    case timedOut = "timed_out"
}

struct GlossaryDiagnosticEvent: Encodable {
    struct Flags: Encodable {
        let speech: Bool
        let formatting: Bool
    }
    let timestamp: Date
    let requestID: UUID
    let glossaryRevision: UUID
    let stage: GlossaryStage
    let status: GlossaryStageStatus
    let engine: String
    let modelID: String?
    let requested: Flags
    let effective: GlossaryEffective
    let submittedEntryIDs: [UUID]
    let omittedEntryCount: Int
    let counts: [GlossaryCount]?
    let reason: GlossaryFailureReason?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(1, forKey: .schemaVersion)
        try c.encode(1, forKey: .matchingVersion)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(requestID, forKey: .requestID)
        try c.encode(glossaryRevision, forKey: .glossaryRevision)
        try c.encode(stage, forKey: .stage)
        try c.encode(status, forKey: .status)
        try c.encode(engine, forKey: .engine)
        try c.encode(modelID, forKey: .modelID)
        try c.encode(requested, forKey: .requested)
        try c.encode(effective, forKey: .effective)
        try c.encode(submittedEntryIDs, forKey: .submittedEntryIDs)
        try c.encode(omittedEntryCount, forKey: .omittedEntryCount)
        try c.encode(counts, forKey: .counts)
        try c.encodeIfPresent(reason, forKey: .reason)
    }
    private enum Key: String, CodingKey {
        case schemaVersion, matchingVersion, timestamp, requestID, glossaryRevision, stage, status,
            engine, modelID,
            requested, effective, submittedEntryIDs, omittedEntryCount, counts, reason
    }
}

@Observable @MainActor
final class GlossaryDiagnostics {
    private(set) var generation: UUID?
    private(set) var currentFile: URL?
    private(set) var errorMessage: String?
    let directory: URL
    private var handle: FileHandle?
    private var written = 0
    private var totalWritten = 0
    private let fileLimit: Int
    private let totalLimit: Int

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(
            path: ".kotodamavoice/logs/glossary"),
        fileLimit: Int = 10 * 1_024 * 1_024, totalLimit: Int = 100 * 1_024 * 1_024
    ) {
        self.directory = directory
        self.fileLimit = fileLimit
        self.totalLimit = totalLimit
    }

    func setEnabled(_ enabled: Bool) {
        close()
        generation = nil
        guard enabled else { return }
        do {
            try Self.rejectSymlinks(directory)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            totalWritten = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
            )
            .filter { $0.pathExtension == "jsonl" }
            .reduce(0) { total, file in
                try Self.rejectSymlinks(file)
                return total + (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            guard totalWritten < totalLimit else { throw CocoaError(.fileWriteOutOfSpace) }
            try openFile()
            generation = UUID()
            errorMessage = nil
        } catch { fail() }
    }

    func record(_ event: GlossaryDiagnosticEvent, generation expected: UUID?) {
        guard let expected, generation == expected, handle != nil else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(event)
            data.append(0x0a)
            guard data.count <= fileLimit, totalWritten + data.count <= totalLimit else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            if written + data.count > fileLimit {
                close()
                try openFile()
            }
            try handle?.write(contentsOf: data)
            try handle?.synchronize()
            written += data.count
            totalWritten += data.count
        } catch { fail() }
    }

    func openDirectory() { NSWorkspace.shared.open(directory) }

    private func openFile() throws {
        try Self.rejectSymlinks(directory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = directory.appending(
            path: "Glossary-\(formatter.string(from: Date()))-\(UUID()).jsonl")
        let descriptor = Darwin.open(
            url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        currentFile = url
        written = 0
    }

    private func close() {
        try? handle?.close()
        handle = nil
    }
    private func fail() {
        close()
        generation = nil
        errorMessage = "用語の診断記録を停止しました。保存先と空き容量を確認し、不要なログを削除してから再度オンにしてください。"
    }
    private static func rejectSymlinks(_ url: URL) throws {
        var path = url
        while path.path != "/" {
            if let type = try? FileManager.default.attributesOfItem(atPath: path.path)[.type]
                as? FileAttributeType,
                type == .typeSymbolicLink
            {
                throw CocoaError(.fileWriteNoPermission)
            }
            path.deleteLastPathComponent()
        }
    }
}

@Observable @MainActor
final class GlossarySession {
    let settings: GlossarySettingsStore
    let diagnostics: GlossaryDiagnostics
    private(set) var snapshot: GlossarySnapshot?
    private(set) var omittedSpeechCount = 0
    private var recordedStages = Set<GlossaryStage>()

    init(settings: GlossarySettingsStore, diagnostics: GlossaryDiagnostics) {
        self.settings = settings
        self.diagnostics = diagnostics
        diagnostics.setEnabled(settings.diagnosticsEnabled)
    }
    func begin() {
        snapshot = GlossarySnapshot(
            document: settings.isReadable ? settings.document : GlossaryDocument(),
            speech: settings.useForSpeech, formatting: settings.useForFormatting,
            generation: diagnostics.generation)
        recordedStages.removeAll()
    }
    func finish() {
        snapshot = nil
        recordedStages.removeAll()
    }
    func setDiagnostics(_ value: Bool) {
        settings.setDiagnostics(value)
        diagnostics.setEnabled(value)
    }
    func record(
        requestID: PipelineRequestID, stage: GlossaryStage, status: GlossaryStageStatus,
        text: String?, effective: GlossaryEffective, engine: String = "unknown",
        modelID: String? = nil,
        submitted: [UUID] = [], reason: GlossaryFailureReason? = nil
    ) {
        guard let snapshot, recordedStages.insert(stage).inserted else { return }
        if stage == .speech {
            omittedSpeechCount =
                effective == .applied ? snapshot.document.entries.count - submitted.count : 0
        }
        diagnostics.record(
            snapshot.event(
                requestID: requestID, stage: stage, status: status, text: text,
                effective: effective, engine: engine, modelID: modelID, submitted: submitted,
                reason: reason), generation: snapshot.generation)
    }
}
