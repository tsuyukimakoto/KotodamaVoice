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

enum FormatterEngineSelectionOutcome: Equatable {
    case applied
    case requiresModel(ModelManifestEntry)
    case unavailable
}

@Observable
@MainActor
final class FormatterEngineSelectionCoordinator {
    private(set) var pendingModel: ModelManifestEntry?

    @ObservationIgnored
    private let settings: FormatterSettingsStore

    @ObservationIgnored
    private let formatterModels: [ModelManifestEntry]

    @ObservationIgnored
    private let isInstalledAndSelected: (ModelManifestEntry) -> Bool

    init(
        settings: FormatterSettingsStore,
        models: [ModelManifestEntry],
        isInstalledAndSelected: @escaping (ModelManifestEntry) -> Bool
    ) {
        self.settings = settings
        formatterModels = models.filter { $0.purpose == .formatter }
        self.isInstalledAndSelected = isInstalledAndSelected

        if settings.engine == .builtIn,
           !formatterModels.contains(where: isInstalledAndSelected) {
            settings.setEngine(.off)
        }
    }

    func select(_ engine: FormattingEngine) -> FormatterEngineSelectionOutcome {
        guard engine == .builtIn else {
            pendingModel = nil
            settings.setEngine(engine)
            return .applied
        }

        if formatterModels.contains(where: isInstalledAndSelected) {
            pendingModel = nil
            settings.setEngine(.builtIn)
            return .applied
        }

        guard let model = acquisitionTarget else {
            return .unavailable
        }
        pendingModel = model
        return .requiresModel(model)
    }

    func beginPendingModelAcquisition() -> ModelManifestEntry? {
        pendingModel
    }

    func cancelPendingModelAcquisition() {
        pendingModel = nil
    }

    func modelAcquisitionDidFinish(
        _ model: ModelManifestEntry,
        succeeded: Bool
    ) {
        guard pendingModel?.id == model.id else { return }
        defer { pendingModel = nil }
        guard succeeded, isInstalledAndSelected(model) else { return }
        settings.setEngine(.builtIn)
    }

    func modelWasDeleted(_ model: ModelManifestEntry) {
        if pendingModel?.id == model.id {
            pendingModel = nil
        }
        if model.purpose == .formatter, settings.engine == .builtIn {
            settings.setEngine(.off)
        }
    }

    private var acquisitionTarget: ModelManifestEntry? {
        formatterModels.first(where: \.isDefault)
            ?? (formatterModels.count == 1 ? formatterModels.first : nil)
    }
}

@Observable
@MainActor
final class FormatterSettingsStore {
    private(set) var engine: FormattingEngine
    private(set) var promptSource: FormattingPromptSource
    private(set) var customPrompt: String
    let defaultPrompt: VersionedFormattingPrompt

    @ObservationIgnored
    private let defaults: UserDefaults?

    private static let engineKey = "formatter.engine"
    private static let promptSourceKey = "formatter.prompt.source"
    private static let customPromptKey = "formatter.prompt.custom"

    init(
        defaults: UserDefaults = .standard,
        defaultPrompt: VersionedFormattingPrompt = DefaultFormattingPromptResource
            .loadRequired()
    ) {
        self.defaults = defaults
        self.defaultPrompt = defaultPrompt
        engine = defaults.string(forKey: Self.engineKey)
            .flatMap(FormattingEngine.init(rawValue:))
            ?? .off
        promptSource = defaults.string(forKey: Self.promptSourceKey)
            .flatMap(FormattingPromptSource.init(rawValue:))
            ?? .defaultPrompt
        customPrompt = defaults.string(forKey: Self.customPromptKey) ?? ""
    }

    init(engine: FormattingEngine) {
        defaults = nil
        defaultPrompt = DefaultFormattingPromptResource.loadRequired()
        self.engine = engine
        promptSource = .defaultPrompt
        customPrompt = ""
    }

    var activePrompt: String {
        switch promptSource {
        case .defaultPrompt:
            defaultPrompt.text
        case .custom:
            customPrompt
        }
    }

    func setEngine(_ engine: FormattingEngine) {
        self.engine = engine
        defaults?.set(engine.rawValue, forKey: Self.engineKey)
    }

    func setPromptSource(_ source: FormattingPromptSource) {
        promptSource = source
        defaults?.set(source.rawValue, forKey: Self.promptSourceKey)
    }

    func setCustomPrompt(_ prompt: String) {
        customPrompt = prompt
        defaults?.set(prompt, forKey: Self.customPromptKey)
    }

    func importDefaultIntoCustom(
        overwriteConfirmed: Bool = false
    ) -> DefaultPromptImportResult {
        let hasModifiedCustom = !customPrompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty && customPrompt != defaultPrompt.text
        guard !hasModifiedCustom || overwriteConfirmed else {
            return .requiresConfirmation
        }
        setCustomPrompt(defaultPrompt.text)
        setPromptSource(.custom)
        return .imported
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
            formattedText = FormattingOutputValidator.validated(
                candidate,
                source: transcription.text
            )
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

enum FormattingOutputValidator {
    private static let absoluteMaximumByteCount = 256 * 1_024
    private static let minimumRelativeLimit = 1_024
    private static let explanatoryPrefixes = [
        "整形しました",
        "整形後の文章",
        "以下が整形",
        "以下のとおり整形",
        "以下のように整形",
        "結果は次のとおり",
        "here is the formatted",
        "here's the formatted",
        "the formatted text",
    ]
    private static let controlMarkers = [
        "<start_of_turn>",
        "<end_of_turn>",
        "<|begin_of_text|>",
        "<|end_of_text|>",
        "<|eot_id|>",
        "```",
    ]

    static func validated(_ candidate: String, source: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let relativeLimit = max(
            minimumRelativeLimit,
            source.utf8.count * 2 + 256
        )
        guard candidate.utf8.count <= min(
            absoluteMaximumByteCount,
            relativeLimit
        ) else {
            return nil
        }

        let lowercased = trimmed.lowercased()
        guard !explanatoryPrefixes.contains(where: lowercased.hasPrefix),
              !controlMarkers.contains(where: candidate.contains)
        else {
            return nil
        }
        return candidate
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
