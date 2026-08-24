import Foundation
import KotodamaCore
import Testing

@Test func formatterRuntimeLoadsAndUnloadsModel() throws {
    let backend = FixtureLlamaBackend()
    let modelURL = URL(fileURLWithPath: "/fixture/model.gguf")
    let runtime = FormatterRuntime(
        backend: backend,
        resolveModelURL: { modelID in
            #expect(modelID == "formatter-model")
            return modelURL
        }
    )

    try runtime.load(modelID: "formatter-model")
    runtime.unload()

    #expect(backend.loadedURLs == [modelURL])
    #expect(backend.unloadedModelCount == 1)
}

@Test func formatterRuntimePassesPromptAndTextToBackend() throws {
    let backend = FixtureLlamaBackend()
    backend.result = .success("整形された文章です。")
    let runtime = FormatterRuntime(
        backend: backend,
        resolveModelURL: { _ in URL(fileURLWithPath: "/fixture/model.gguf") }
    )
    try runtime.load(modelID: "formatter-model")

    let text = try runtime.format(
        text: "ええと整形する文章です",
        prompt: "本文だけを返してください",
        requestID: PipelineRequestID()
    )

    #expect(text == "整形された文章です。")
    #expect(backend.receivedText == "ええと整形する文章です")
    #expect(backend.receivedPrompt == "本文だけを返してください")
}

@Test func formatterRuntimeSupportsContinuousRequestsWithOneLoadedModel() throws {
    let backend = FixtureLlamaBackend()
    let runtime = FormatterRuntime(
        backend: backend,
        resolveModelURL: { _ in URL(fileURLWithPath: "/fixture/model.gguf") }
    )
    try runtime.load(modelID: "formatter-model")

    let first = try runtime.format(
        text: "一回目",
        prompt: "指示",
        requestID: PipelineRequestID()
    )
    backend.result = .success("二回目の結果")
    let second = try runtime.format(
        text: "二回目",
        prompt: "指示",
        requestID: PipelineRequestID()
    )

    #expect(first == "fixture")
    #expect(second == "二回目の結果")
    #expect(backend.loadedURLs.count == 1)
}

@Test func formatterOutputSanitizerRemovesControlTokens() {
    let output = FormatterOutputSanitizer.clean(
        "<bos><start_of_turn>model\n整形結果<end_of_turn><eos>"
    )

    #expect(output == "model\n整形結果")
}

@Test func formatterRuntimeReportsModelLoadFailure() {
    let backend = FixtureLlamaBackend()
    backend.loadError = FixtureLlamaError.loadFailed
    let runtime = FormatterRuntime(
        backend: backend,
        resolveModelURL: { _ in URL(fileURLWithPath: "/fixture/model.gguf") }
    )

    #expect(throws: FixtureLlamaError.loadFailed) {
        try runtime.load(modelID: "formatter-model")
    }
}

@Test func formatterRuntimeRejectsFormattingWithoutLoadedModel() {
    let runtime = FormatterRuntime(
        backend: FixtureLlamaBackend(),
        resolveModelURL: { _ in URL(fileURLWithPath: "/fixture/model.gguf") }
    )

    #expect(throws: WorkerRuntimeError.processingFailed) {
        try runtime.format(
            text: "本文",
            prompt: "指示",
            requestID: PipelineRequestID()
        )
    }
}

@Test func formatterRuntimePropagatesGenerationFailure() throws {
    let backend = FixtureLlamaBackend()
    backend.result = .failure(FixtureLlamaError.generationFailed)
    let runtime = FormatterRuntime(
        backend: backend,
        resolveModelURL: { _ in URL(fileURLWithPath: "/fixture/model.gguf") }
    )
    try runtime.load(modelID: "formatter-model")

    #expect(throws: FixtureLlamaError.generationFailed) {
        try runtime.format(
            text: "本文",
            prompt: "指示",
            requestID: PipelineRequestID()
        )
    }
}

@Test func formatterRuntimeCancelsSpecificRequest() async throws {
    let backend = FixtureLlamaBackend()
    backend.waitForCancellation = true
    let runtime = FormatterRuntime(
        backend: backend,
        resolveModelURL: { _ in URL(fileURLWithPath: "/fixture/model.gguf") }
    )
    try runtime.load(modelID: "formatter-model")
    let requestID = PipelineRequestID()

    let formatting = Task.detached {
        try runtime.format(text: "本文", prompt: "指示", requestID: requestID)
    }
    #expect(await backend.waitUntilStarted())
    runtime.cancel(requestID: requestID)

    await #expect(throws: WorkerRuntimeError.cancelled) {
        try await formatting.value
    }
}

@Test func formatterRuntimeCancelAllStopsActiveRequestBeforeUnload() async throws {
    let backend = FixtureLlamaBackend()
    backend.waitForCancellation = true
    let runtime = FormatterRuntime(
        backend: backend,
        resolveModelURL: { _ in URL(fileURLWithPath: "/fixture/model.gguf") }
    )
    try runtime.load(modelID: "formatter-model")

    let formatting = Task.detached {
        try runtime.format(
            text: "本文",
            prompt: "指示",
            requestID: PipelineRequestID()
        )
    }
    #expect(await backend.waitUntilStarted())
    runtime.cancelAll()

    await #expect(throws: WorkerRuntimeError.cancelled) {
        try await formatting.value
    }
    runtime.unload()
    #expect(backend.unloadedModelCount == 1)
}

@Test func workerServiceFormatsUsingRequestOptions() throws {
    let backend = FixtureLlamaBackend()
    backend.result = .success("整形結果")
    let runtime = FormatterRuntime(
        backend: backend,
        resolveModelURL: { _ in URL(fileURLWithPath: "/fixture/model.gguf") }
    )
    let service = WorkerService(runtime: runtime)
    service.perform(
        WorkerRequest(
            requestID: PipelineRequestID(),
            operation: .loadModel,
            modelID: "formatter-model"
        )
    ) { reply in
        #expect(reply.failure == nil)
    }

    var formatReply: WorkerReply?
    service.perform(
        WorkerRequest(
            requestID: PipelineRequestID(),
            operation: .format,
            options: ["text": "原文", "prompt": "指示"]
        )
    ) { formatReply = $0 }

    #expect(formatReply?.failure == nil)
    #expect(String(data: try #require(formatReply?.payload), encoding: .utf8) == "整形結果")
}

@Test func pinnedLlamaRuntimeSupportsContinuousGenerationAndShutdown() async throws {
    guard let modelPath = ProcessInfo.processInfo.environment[
        "KOTODAMA_FORMATTER_MODEL"
    ] else {
        return
    }
    let modelURL: URL
    if modelPath.hasPrefix("/") {
        modelURL = URL(fileURLWithPath: modelPath)
    } else {
        modelURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: modelPath)
    }
    let runtime = FormatterRuntime(
        resolveModelURL: { _ in modelURL }
    )
    let service = WorkerService(runtime: runtime)
    var loadReply: WorkerReply?
    service.perform(
        WorkerRequest(
            requestID: PipelineRequestID(),
            operation: .loadModel,
            modelID: "gemma-4-e4b-it-qat-q4-0"
        )
    ) { loadReply = $0 }
    #expect(loadReply?.failure == nil)

    for sourceText in ["ええと、今日は晴れです", "会議は2026年9月15日です"] {
        let requiredOutput = try runtime.format(
            text: sourceText,
            prompt: "意味と事実を変えず、自然な日本語に整えて本文だけを返してください。",
            requestID: PipelineRequestID()
        )
        #expect(requiredOutput.isEmpty == false)
        #expect(!requiredOutput.contains("<start_of_turn>"))
        #expect(!requiredOutput.contains("<end_of_turn>"))
    }

    let cancelledRequestID = PipelineRequestID()
    let runtimeBox = UncheckedSendableBox(runtime)
    let formatting = Task.detached {
        try runtimeBox.value.format(
            text: String(repeating: "長い入力です。", count: 200),
            prompt: "本文だけを返してください。",
            requestID: cancelledRequestID
        )
    }
    try await Task.sleep(for: .milliseconds(100))
    runtime.cancel(requestID: cancelledRequestID)
    await #expect(throws: WorkerRuntimeError.cancelled) {
        try await formatting.value
    }

    var shutdownReply: WorkerReply?
    service.perform(
        WorkerRequest(
            requestID: PipelineRequestID(),
            operation: .shutdown
        )
    ) { shutdownReply = $0 }
    #expect(shutdownReply?.failure == nil)
}

private enum FixtureLlamaError: Error {
    case loadFailed
    case generationFailed
}

private final class FixtureLlamaBackend: LlamaBackend, @unchecked Sendable {
    var loadError: Error?
    var result: Result<String, Error> = .success("fixture")
    var waitForCancellation = false
    private let lock = NSLock()
    private var hasStarted = false
    private(set) var loadedURLs: [URL] = []
    private(set) var unloadedModelCount = 0
    private(set) var receivedText: String?
    private(set) var receivedPrompt: String?

    func loadModel(at url: URL) throws -> AnyObject {
        if let loadError { throw loadError }
        loadedURLs.append(url)
        return FixtureModel()
    }

    func format(
        model: AnyObject,
        text: String,
        prompt: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> String {
        receivedText = text
        receivedPrompt = prompt
        lock.lock()
        hasStarted = true
        lock.unlock()
        if waitForCancellation {
            while !isCancelled() {
                Thread.sleep(forTimeInterval: 0.001)
            }
            throw WorkerRuntimeError.cancelled
        }
        return try result.get()
    }

    func unloadModel(_ model: AnyObject) {
        unloadedModelCount += 1
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<1_000 {
            if isStarted { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasStarted
    }
}

private final class FixtureModel {}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
