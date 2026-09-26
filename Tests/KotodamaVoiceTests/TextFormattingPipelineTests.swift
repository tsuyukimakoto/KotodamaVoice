import Foundation
import KotodamaCore
import Testing
@testable import KotodamaVoice

@Test @MainActor
func formatterSelectionDefaultsToOffAndPersistsChanges() throws {
    let suiteName = "com.tsuyukimakoto.KotodamaVoiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = FormatterSettingsStore(defaults: defaults)
    #expect(settings.engine == .off)

    settings.setEngine(.external)

    #expect(FormatterSettingsStore(defaults: defaults).engine == .external)
}

@Test @MainActor
func builtInFormatterSelectionStaysPendingUntilItsModelIsReady() throws {
    let suiteName = "com.tsuyukimakoto.FormatterSelectionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = FormatterSettingsStore(defaults: defaults)
    settings.setEngine(.external)
    let model = formatterSelectionModel()
    var isReady = false
    let selection = FormatterEngineSelectionCoordinator(
        settings: settings,
        models: [model],
        isInstalledAndSelected: { _ in isReady }
    )

    #expect(selection.select(.builtIn) == .requiresModel(model))
    #expect(settings.engine == .external)
    #expect(FormatterSettingsStore(defaults: defaults).engine == .external)
    #expect(selection.pendingModel == model)
    #expect(selection.beginPendingModelAcquisition() == model)

    isReady = true
    selection.modelAcquisitionDidFinish(model, succeeded: true)

    #expect(settings.engine == .builtIn)
    #expect(FormatterSettingsStore(defaults: defaults).engine == .builtIn)
    #expect(selection.pendingModel == nil)
}

@Test @MainActor
func cancellingOrFailingFormatterModelAcquisitionKeepsCurrentEngine() {
    let settings = FormatterSettingsStore(engine: .external)
    let model = formatterSelectionModel()
    let selection = FormatterEngineSelectionCoordinator(
        settings: settings,
        models: [model],
        isInstalledAndSelected: { _ in false }
    )

    #expect(selection.select(.builtIn) == .requiresModel(model))
    selection.cancelPendingModelAcquisition()
    #expect(settings.engine == .external)
    #expect(selection.pendingModel == nil)

    #expect(selection.select(.builtIn) == .requiresModel(model))
    selection.modelAcquisitionDidFinish(model, succeeded: false)
    #expect(settings.engine == .external)
    #expect(selection.pendingModel == nil)
}

@Test @MainActor
func installedFormatterCanBeSelectedImmediatelyAndDeletionReturnsToOff() {
    let settings = FormatterSettingsStore(engine: .off)
    let model = formatterSelectionModel()
    let selection = FormatterEngineSelectionCoordinator(
        settings: settings,
        models: [model],
        isInstalledAndSelected: { _ in true }
    )

    #expect(selection.select(.builtIn) == .applied)
    #expect(settings.engine == .builtIn)

    selection.modelWasDeleted(model)

    #expect(settings.engine == .off)
}

@Test @MainActor
func unavailablePersistedBuiltInFormatterIsResetToOff() {
    let settings = FormatterSettingsStore(engine: .builtIn)
    _ = FormatterEngineSelectionCoordinator(
        settings: settings,
        models: [formatterSelectionModel()],
        isInstalledAndSelected: { _ in false }
    )

    #expect(settings.engine == .off)
}

@Test @MainActor
func formatterOffPassesTheTranscriptionThroughUnchanged() async throws {
    let fixture = FormattingPipelineFixture(engine: .off)

    let output = try await fixture.pipeline.process(fixture.transcription)

    #expect(output.text == fixture.transcription.text)
    #expect(!output.usedFallback)
    #expect(fixture.builtIn.callCount == 0)
    #expect(fixture.external.callCount == 0)
    #expect(fixture.store.state == .outputting(fixture.requestID))
}

@Test(arguments: [FormattingEngine.builtIn, .external])
@MainActor
func selectedFormatterProvidesTheOutput(engine: FormattingEngine) async throws {
    let fixture = FormattingPipelineFixture(engine: engine)

    let output = try await fixture.pipeline.process(fixture.transcription)

    #expect(output.text == "formatted by \(engine.rawValue)")
    #expect(!output.usedFallback)
    #expect(fixture.selectedFormatter.callCount == 1)
    #expect(fixture.unselectedFormatter.callCount == 0)
    #expect(fixture.store.state == .outputting(fixture.requestID))
}

@Test(arguments: [FormattingEngine.builtIn, .external])
@MainActor
func formatterFailureReturnsTheOriginalWithoutTryingAnotherEngine(
    engine: FormattingEngine
) async throws {
    let fixture = FormattingPipelineFixture(
        engine: engine,
        selectedResult: .failure(FormattingTestError.failed)
    )

    let output = try await fixture.pipeline.process(fixture.transcription)

    #expect(output.text == fixture.transcription.text)
    #expect(output.usedFallback)
    #expect(fixture.selectedFormatter.callCount == 1)
    #expect(fixture.unselectedFormatter.callCount == 0)
    #expect(fixture.store.state == .outputting(fixture.requestID))
}

@Test @MainActor
func formatterEmptyOutputReturnsTheOriginal() async throws {
    let fixture = FormattingPipelineFixture(
        engine: .builtIn,
        selectedResult: .success(" \n ")
    )

    let output = try await fixture.pipeline.process(fixture.transcription)

    #expect(output.text == fixture.transcription.text)
    #expect(output.usedFallback)
    #expect(fixture.builtIn.callCount == 1)
    #expect(fixture.external.callCount == 0)
    #expect(fixture.store.state == .outputting(fixture.requestID))
}

@Test(arguments: FormattingContractViolationCase.allCases)
@MainActor
func formatterContractViolationReturnsTheOriginalWithoutTryingAnotherEngine(
    violation: FormattingContractViolationCase
) async throws {
    let fixture = FormattingPipelineFixture(
        engine: .builtIn,
        selectedResult: .success(violation.output)
    )

    let output = try await fixture.pipeline.process(fixture.transcription)

    #expect(output.text == fixture.transcription.text)
    #expect(output.usedFallback)
    #expect(fixture.builtIn.callCount == 1)
    #expect(fixture.external.callCount == 0)
    #expect(fixture.store.state == .outputting(fixture.requestID))
}

enum FormattingContractViolationCase: CaseIterable, Sendable {
    case excessiveLength
    case explanatoryProse
    case controlToken

    var output: String {
        switch self {
        case .excessiveLength:
            String(repeating: "長", count: 5_000)
        case .explanatoryProse:
            "整形しました。\noriginal transcription"
        case .controlToken:
            "<start_of_turn>model\noriginal transcription<end_of_turn>"
        }
    }
}

private enum FormattingTestError: Error {
    case failed
}

private func formatterSelectionModel() -> ModelManifestEntry {
    ModelManifestEntry(
        id: "formatter-model",
        displayName: "Formatter Model",
        purpose: .formatter,
        version: "1",
        sourceURL: URL(string: "https://www.tsuyukimakoto.com/formatter.gguf")!,
        revision: String(repeating: "a", count: 40),
        fileName: "formatter.gguf",
        byteCount: 1_024,
        sha256: String(repeating: "b", count: 64),
        licenseName: "Apache-2.0",
        licenseFile: "Apache-2.0.txt",
        licenseURL: URL(string: "https://www.tsuyukimakoto.com/license")!,
        runtime: .llama
    )
}

@MainActor
private final class FormattingPipelineFixture {
    let requestID = PipelineRequestID()
    let store: PipelineStore
    let builtIn: TextFormatterSpy
    let external: TextFormatterSpy
    let pipeline: TextFormattingPipeline

    var transcription: LocalTranscription {
        LocalTranscription(requestID: requestID, text: "original transcription")
    }

    var selectedFormatter: TextFormatterSpy {
        settings.engine == .builtIn ? builtIn : external
    }

    var unselectedFormatter: TextFormatterSpy {
        settings.engine == .builtIn ? external : builtIn
    }

    private let settings: FormatterSettingsStore

    init(
        engine: FormattingEngine,
        selectedResult: Result<String, Error>? = nil
    ) {
        settings = FormatterSettingsStore(engine: engine)
        store = PipelineStore(initialState: .transcribing(requestID))
        let coordinator = PipelineCoordinator(store: store)
        builtIn = TextFormatterSpy(
            result: engine == .builtIn
                ? selectedResult ?? .success("formatted by builtIn")
                : .success("unexpected builtIn")
        )
        external = TextFormatterSpy(
            result: engine == .external
                ? selectedResult ?? .success("formatted by external")
                : .success("unexpected external")
        )
        pipeline = TextFormattingPipeline(
            coordinator: coordinator,
            settings: settings,
            builtIn: builtIn,
            external: external
        )
    }
}

@MainActor
private final class TextFormatterSpy: TextFormatting {
    let result: Result<String, Error>
    private(set) var callCount = 0

    init(result: Result<String, Error>) {
        self.result = result
    }

    func format(
        _ text: String,
        requestID: PipelineRequestID
    ) async throws -> String {
        callCount += 1
        return try result.get()
    }
}
