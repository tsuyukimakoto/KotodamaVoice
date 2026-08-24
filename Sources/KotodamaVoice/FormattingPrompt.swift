import Foundation

struct VersionedFormattingPrompt: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let identifier: String
    let version: Int
    let text: String
}

enum FormattingPromptSource: String, CaseIterable, Identifiable, Sendable {
    case defaultPrompt
    case custom

    var id: Self { self }

    var displayName: String {
        switch self {
        case .defaultPrompt:
            "Default"
        case .custom:
            "Custom"
        }
    }
}

enum DefaultPromptImportResult: Equatable {
    case imported
    case requiresConfirmation
}

enum DefaultFormattingPromptResource {
    private static let resourceName = "FormattingPrompt-v1"

    static func decode(_ data: Data) throws -> VersionedFormattingPrompt {
        let prompt = try JSONDecoder().decode(
            VersionedFormattingPrompt.self,
            from: data
        )
        guard prompt.schemaVersion == 1,
              prompt.version > 0,
              !prompt.identifier.isEmpty,
              !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DefaultFormattingPromptError.invalidResource
        }
        return prompt
    }

    static func loadRequired(bundle: Bundle = .main) -> VersionedFormattingPrompt {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: "json"
        ) else {
            preconditionFailure("Versioned default formatting prompt is missing")
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            preconditionFailure("Versioned default formatting prompt is invalid")
        }
    }
}

private enum DefaultFormattingPromptError: Error {
    case invalidResource
}
