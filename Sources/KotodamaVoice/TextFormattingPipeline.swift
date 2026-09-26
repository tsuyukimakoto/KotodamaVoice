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
            !formatterModels.contains(where: isInstalledAndSelected)
        {
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
        defaultPrompt: VersionedFormattingPrompt =
            DefaultFormattingPromptResource
            .loadRequired()
    ) {
        self.defaults = defaults
        self.defaultPrompt = defaultPrompt
        engine =
            defaults.string(forKey: Self.engineKey)
            .flatMap(FormattingEngine.init(rawValue:))
            ?? .off
        promptSource =
            defaults.string(forKey: Self.promptSourceKey)
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
        let hasModifiedCustom =
            !customPrompt.trimmingCharacters(
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
    func format(_ text: String, requestID: PipelineRequestID, glossary: [GlossaryEntry])
        async throws -> String

    func format(
        _ text: String,
        requestID: PipelineRequestID
    ) async throws -> String
}

extension TextFormatting {
    func format(_ text: String, requestID: PipelineRequestID, glossary: [GlossaryEntry])
        async throws -> String
    {
        guard glossary.isEmpty else { throw WorkerRuntimeError.invalidInput }
        return try await format(text, requestID: requestID)
    }
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
    private let glossary: GlossarySession?
    private let permitsExternalGlossary: () -> Bool
    private let modelIdentifier: (FormattingEngine) -> String?

    init(
        coordinator: PipelineCoordinator,
        settings: FormatterSettingsStore,
        builtIn: TextFormatting,
        external: TextFormatting,
        glossary: GlossarySession? = nil,
        permitsExternalGlossary: @escaping () -> Bool = { true },
        modelIdentifier: @escaping (FormattingEngine) -> String? = { _ in nil }
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.builtIn = builtIn
        self.external = external
        self.glossary = glossary
        self.permitsExternalGlossary = permitsExternalGlossary
        self.modelIdentifier = modelIdentifier
    }

    func process(
        _ transcription: LocalTranscription
    ) async throws -> FormattingOutput {
        defer { glossary?.finish() }
        let engine = settings.engine
        let modelID = modelIdentifier(engine)
        let snapshot = glossary?.snapshot
        let entries = snapshot?.document.entries ?? []
        let effective: GlossaryEffective =
            engine == .off
            ? .formatterOff
            : snapshot?.formatting != true
                ? .disabled
                : entries.isEmpty
                    ? .empty
                    : engine == .external && !permitsExternalGlossary() ? .consentMissing : .applied
        let submitted = effective == .applied ? entries : []

        _ = try coordinator.completeTranscription(
            requestID: transcription.requestID,
            requiresFormatting: engine != .off
        )
        guard engine != .off else {
            glossary?.record(
                requestID: transcription.requestID, stage: .formatting, status: .skipped, text: nil,
                effective: effective, engine: engine.rawValue)
            return FormattingOutput(
                text: transcription.text,
                usedFallback: false
            )
        }

        let formatter = engine == .builtIn ? builtIn : external
        let formattedText: String?
        var reason: GlossaryFailureReason?
        var cancelled = false
        var usageUnknown = false
        do {
            let candidate = try await formatter.format(
                transcription.text,
                requestID: transcription.requestID,
                glossary: submitted
            )
            formattedText = FormattingOutputValidator.validated(
                candidate,
                source: transcription.text
            )
            if formattedText == nil { reason = .invalidOutput }
        } catch {
            formattedText = nil
            cancelled =
                error is CancellationError
                || (error as? FormatterWorkerClientError) == .workerFailure(.cancelled)
            usageUnknown = true
            let timedOut =
                (error as? WorkerConnectionError) == .timedOut
                || (error as? FormatterWorkerClientError) == .workerFailure(.timedOut)
                || (error as? URLError)?.code == .timedOut
            let capacityExceeded =
                (error as? FormatterWorkerClientError) == .workerFailure(.capacityExceeded)
            reason =
                cancelled
                ? .cancelled
                : timedOut ? .timedOut : capacityExceeded ? .capacityExceeded : .processingFailed

        }
        glossary?.record(
            requestID: transcription.requestID, stage: .formatting,
            status: cancelled ? .cancelled : formattedText == nil ? .fallback : .success,
            text: formattedText,
            effective: usageUnknown && effective == .applied ? .unknown : effective,
            engine: engine.rawValue, modelID: modelID,
            submitted: usageUnknown ? [] : submitted.map(\.id), reason: reason)

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
        guard
            candidate.utf8.count
                <= min(
                    absoluteMaximumByteCount,
                    relativeLimit
                )
        else {
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
