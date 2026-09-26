import Darwin
import Foundation
import KotodamaCore
import Observation

@Observable @MainActor
final class GlossarySettingsStore {
    private(set) var document = GlossaryDocument()
    private(set) var errorMessage: String?
    private(set) var useForSpeech: Bool
    private(set) var useForFormatting: Bool
    private(set) var diagnosticsEnabled: Bool
    private(set) var approvedEndpoints: Set<String>
    private(set) var isReadable = true
    private let directory: URL
    private let defaults: UserDefaults
    private var file: URL { directory.appending(path: "glossary.json") }

    init(
        directory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "com.tsuyukimakoto.KotodamaVoice/Glossary"),
        defaults: UserDefaults = .standard
    ) {
        self.directory = directory
        self.defaults = defaults
        useForSpeech = defaults.bool(forKey: "glossary.speech")
        useForFormatting = defaults.bool(forKey: "glossary.formatting")
        diagnosticsEnabled = defaults.bool(forKey: "glossary.diagnostics")
        approvedEndpoints = Set(defaults.stringArray(forKey: "glossary.approvedEndpoints") ?? [])
        reload()
    }

    func reload() {
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                document = try JSONDecoder().decode(
                    GlossaryDocument.self, from: Data(contentsOf: file)
                ).validated()
            }
            isReadable = true
            errorMessage = nil
        } catch {
            isReadable = false
            errorMessage = "用語集を読み込めませんでした。元のファイルを保持しています。"
        }
    }

    func save(_ entry: GlossaryEntry) throws {
        guard isReadable else { throw CocoaError(.fileReadCorruptFile) }
        var entries = document.entries
        let entry = try entry.validated()
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        try persist(GlossaryDocument(entries: entries))
    }

    func delete(_ id: UUID) throws {
        guard isReadable else { throw CocoaError(.fileReadCorruptFile) }
        try persist(GlossaryDocument(entries: document.entries.filter { $0.id != id }))
    }

    func reset() throws { try persist(GlossaryDocument()) }

    private func persist(_ candidate: GlossaryDocument) throws {
        do {
            let candidate = try candidate.validated()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let temporary = directory.appending(path: ".glossary-\(UUID()).json")
            let descriptor = Darwin.open(
                temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer {
                try? handle.close()
                try? FileManager.default.removeItem(at: temporary)
            }
            try handle.write(contentsOf: JSONEncoder().encode(candidate))
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temporary.path, file.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }

            document = candidate
            isReadable = true
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
            throw error
        }
    }

    static func message(for error: Error) -> String {
        switch error as? GlossaryValidationError {
        case .emptyTerm: "正しい表記を入力してください。"
        case .duplicate: "同じ表記がすでに登録されています。"
        case .tooManyEntries: "登録できる用語は200件までです。"
        case .tooLong: "表記と読みは128文字、説明は256文字以内で入力してください。"
        case .invalidCharacters: "改行や制御文字は使用できません。"
        default: "用語集を保存できませんでした。保存先を確認してください。"
        }
    }

    func setSpeech(_ value: Bool) {
        useForSpeech = value
        defaults.set(value, forKey: "glossary.speech")
    }
    func setFormatting(_ value: Bool) {
        useForFormatting = value
        defaults.set(value, forKey: "glossary.formatting")
    }
    func setDiagnostics(_ value: Bool) {
        diagnosticsEnabled = value
        defaults.set(value, forKey: "glossary.diagnostics")
    }
    func approve(_ endpoint: URL) {
        approvedEndpoints.insert(endpoint.absoluteString)
        defaults.set(Array(approvedEndpoints), forKey: "glossary.approvedEndpoints")
    }
    func permits(_ endpoint: URL) -> Bool {
        (try? ExternalEndpointPolicy.assess(endpoint, purpose: .formatter).isLoopback) == true
            || approvedEndpoints.contains(endpoint.absoluteString)
    }
}
