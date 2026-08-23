import Foundation
import KotodamaCore
import Observation

enum FormattingEngine: String, CaseIterable, Identifiable, Sendable {
    case off
    case builtIn
    case external

    var id: Self { self }

    var displayName: String {
        switch self {
        case .off:
            "Off"
        case .builtIn:
            "内蔵"
        case .external:
            "外部"
        }
    }
}

@Observable
@MainActor
final class FormatterSettingsStore {
    private(set) var engine: FormattingEngine

    @ObservationIgnored
    private let defaults: UserDefaults?

    private static let engineKey = "formatter.engine"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engine = defaults.string(forKey: Self.engineKey)
            .flatMap(FormattingEngine.init(rawValue:))
            ?? .off
    }

    init(engine: FormattingEngine) {
        defaults = nil
        self.engine = engine
    }

    func setEngine(_ engine: FormattingEngine) {
        self.engine = engine
        defaults?.set(engine.rawValue, forKey: Self.engineKey)
    }
}

@MainActor
protocol TextFormatting: AnyObject {
    func format(
        _ text: String,
        requestID: PipelineRequestID
    ) async throws -> String
}

struct FormattingOutput: Equatable {
    let text: String
    let usedFallback: Bool
}

@MainActor
final class TextFormattingPipeline {
    private let coordinator: PipelineCoordinator
    private let settings: FormatterSettingsStore
    private let builtIn: TextFormatting
    private let external: TextFormatting

    init(
        coordinator: PipelineCoordinator,
        settings: FormatterSettingsStore,
        builtIn: TextFormatting,
        external: TextFormatting
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.builtIn = builtIn
        self.external = external
    }

    func process(
        _ transcription: LocalTranscription
    ) async throws -> FormattingOutput {
        let engine = settings.engine
        _ = try coordinator.completeTranscription(
            requestID: transcription.requestID,
            requiresFormatting: engine != .off
        )
        guard engine != .off else {
            return FormattingOutput(
                text: transcription.text,
                usedFallback: false
            )
        }

        let formatter = engine == .builtIn ? builtIn : external
        let formattedText: String?
        do {
            let candidate = try await formatter.format(
                transcription.text,
                requestID: transcription.requestID
            )
            formattedText = candidate.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? nil : candidate
        } catch {
            formattedText = nil
        }
        _ = try coordinator.completeFormatting(
            requestID: transcription.requestID
        )

        guard let formattedText else {
            return FormattingOutput(
                text: transcription.text,
                usedFallback: true
            )
        }
        return FormattingOutput(text: formattedText, usedFallback: false)
    }
}

@MainActor
final class UnavailableTextFormatter: TextFormatting {
    func format(
        _: String,
        requestID _: PipelineRequestID
    ) async throws -> String {
        throw TextFormatterAvailabilityError.notConfigured
    }
}

private enum TextFormatterAvailabilityError: Error {
    case notConfigured
}
