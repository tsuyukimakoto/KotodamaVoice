import Foundation
import KotodamaCore
import Testing
@testable import KotodamaVoice

@Test @MainActor
func formatterSelectionDefaultsToOffAndPersistsChanges() throws {
    let suiteName = "jp.tsuyuki.KotodamaVoiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = FormatterSettingsStore(defaults: defaults)
    #expect(settings.engine == .off)

    settings.setEngine(.external)

    #expect(FormatterSettingsStore(defaults: defaults).engine == .external)
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

private enum FormattingTestError: Error {
    case failed
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
