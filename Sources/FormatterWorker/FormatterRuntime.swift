import Foundation
import KotodamaCore
import llama

protocol LlamaBackend: AnyObject {
    func loadModel(at url: URL) throws -> AnyObject
    func format(
        model: AnyObject,
        text: String,
        prompt: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> String
    func unloadModel(_ model: AnyObject)
}

final class FormatterRuntime: TextFormattingRuntime, @unchecked Sendable {
    private let condition = NSCondition()
    private let backend: LlamaBackend
    private let resolveModelURL: (String) throws -> URL
    private var model: AnyObject?
    private var cancelledRequestIDs = Set<PipelineRequestID>()
    private var activeRequestIDs = Set<PipelineRequestID>()

    init(
        backend: LlamaBackend = CLlamaBackend(),
        resolveModelURL: @escaping (String) throws -> URL
    ) {
        self.backend = backend
        self.resolveModelURL = resolveModelURL
    }

    func load(modelID: String) throws {
        let newModel = try backend.loadModel(at: resolveModelURL(modelID))
        condition.lock()
        cancelledRequestIDs.formUnion(activeRequestIDs)
        while !activeRequestIDs.isEmpty {
            condition.wait()
        }
        let oldModel = model
        model = newModel
        cancelledRequestIDs.removeAll()
        condition.unlock()
        if let oldModel {
            backend.unloadModel(oldModel)
        }
    }

    func format(
        text: String,
        prompt: String,
        requestID: PipelineRequestID
    ) throws -> String {
        guard !text.isEmpty, !prompt.isEmpty else {
            throw WorkerRuntimeError.invalidInput
        }

        condition.lock()
        guard let model else {
            condition.unlock()
            throw WorkerRuntimeError.processingFailed
        }
        guard activeRequestIDs.isEmpty else {
            condition.unlock()
            throw WorkerRuntimeError.processingFailed
        }
        activeRequestIDs.insert(requestID)
        let wasAlreadyCancelled = cancelledRequestIDs.contains(requestID)
        condition.unlock()

        if wasAlreadyCancelled {
            finish(requestID: requestID)
            throw WorkerRuntimeError.cancelled
        }

        defer { finish(requestID: requestID) }
        return try backend.format(
            model: model,
            text: text,
            prompt: prompt,
            isCancelled: { [weak self] in
                self?.isCancelled(requestID) ?? true
            }
        )
    }

    func cancel(requestID: PipelineRequestID) {
        condition.lock()
        cancelledRequestIDs.insert(requestID)
        condition.unlock()
    }

    func cancelAll() {
        condition.lock()
        cancelledRequestIDs.formUnion(activeRequestIDs)
        condition.unlock()
    }

    func unload() {
        condition.lock()
        cancelledRequestIDs.formUnion(activeRequestIDs)
        while !activeRequestIDs.isEmpty {
            condition.wait()
        }
        let oldModel = model
        model = nil
        cancelledRequestIDs.removeAll()
        condition.unlock()
        if let oldModel {
            backend.unloadModel(oldModel)
        }
    }

    private func isCancelled(_ requestID: PipelineRequestID) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelledRequestIDs.contains(requestID)
    }

    private func finish(requestID: PipelineRequestID) {
        condition.lock()
        activeRequestIDs.remove(requestID)
        cancelledRequestIDs.remove(requestID)
        condition.broadcast()
        condition.unlock()
    }
}

enum FormatterRuntimeBackendError: Error {
    case modelLoadFailed
    case invalidModelHandle
    case contextCreationFailed
    case tokenizationFailed
    case promptTooLong
    case decodeFailed(Int32)
    case samplerCreationFailed
    case tokenConversionFailed
    case invalidUTF8
}

struct LlamaGenerationMetrics: Equatable, Sendable {
    let promptTokenCount: Int
    let generatedTokenCount: Int
    let promptMilliseconds: Double
    let generationMilliseconds: Double
}

final class CLlamaBackend: LlamaBackend {
    private static let initializeBackend: Void = {
        llama_backend_init()
    }()

    private let maximumOutputTokens: Int32
    private let metricsLock = NSLock()
    private var storedMetrics: LlamaGenerationMetrics?

    var lastMetrics: LlamaGenerationMetrics? {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return storedMetrics
    }

    init(maximumOutputTokens: Int32 = 512) {
        self.maximumOutputTokens = maximumOutputTokens
    }

    func loadModel(at url: URL) throws -> AnyObject {
        _ = Self.initializeBackend
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = 999
        let model = url.path.withCString {
            llama_model_load_from_file($0, parameters)
        }
        guard let model else {
            throw FormatterRuntimeBackendError.modelLoadFailed
        }
        return LlamaModelHandle(model: model)
    }

    func format(
        model: AnyObject,
        text: String,
        prompt: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> String {
        guard let handle = model as? LlamaModelHandle,
              let modelPointer = handle.model
        else {
            throw FormatterRuntimeBackendError.invalidModelHandle
        }
        if isCancelled() {
            throw WorkerRuntimeError.cancelled
        }

        let userMessage = "\(prompt)\n\n入力:\n\(text)"
        let fullPrompt = try applyChatTemplate(
            userMessage: userMessage,
            model: modelPointer
        )
        guard let vocabulary = llama_model_get_vocab(modelPointer) else {
            throw FormatterRuntimeBackendError.invalidModelHandle
        }
        let promptTokens = try tokenize(fullPrompt, vocabulary: vocabulary)
        let requiredContext = promptTokens.count + Int(maximumOutputTokens)
        guard requiredContext <= 8_192 else {
            throw FormatterRuntimeBackendError.promptTooLong
        }

        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(max(requiredContext, 512))
        contextParameters.n_batch = UInt32(promptTokens.count)
        contextParameters.no_perf = true
        guard let context = llama_init_from_model(modelPointer, contextParameters) else {
            throw FormatterRuntimeBackendError.contextCreationFailed
        }
        defer { llama_free(context) }

        var samplerParameters = llama_sampler_chain_default_params()
        samplerParameters.no_perf = true
        guard let sampler = llama_sampler_chain_init(samplerParameters) else {
            throw FormatterRuntimeBackendError.samplerCreationFailed
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var mutablePromptTokens = promptTokens
        let promptBatch = mutablePromptTokens.withUnsafeMutableBufferPointer {
            llama_batch_get_one($0.baseAddress, Int32($0.count))
        }
        let clock = ContinuousClock()
        let promptStart = clock.now
        let promptDecodeResult = llama_decode(context, promptBatch)
        guard promptDecodeResult == 0 else {
            throw FormatterRuntimeBackendError.decodeFailed(promptDecodeResult)
        }
        let promptEnd = clock.now

        var output = Data()
        var generatedTokenCount = 0
        let generationStart = clock.now
        for _ in 0..<maximumOutputTokens {
            if isCancelled() {
                throw WorkerRuntimeError.cancelled
            }
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) {
                break
            }
            generatedTokenCount += 1
            output.append(try piece(for: token, vocabulary: vocabulary))
            var nextToken = token
            let nextBatch = llama_batch_get_one(&nextToken, 1)
            let decodeResult = llama_decode(context, nextBatch)
            guard decodeResult == 0 else {
                throw FormatterRuntimeBackendError.decodeFailed(decodeResult)
            }
        }

        guard let result = String(data: output, encoding: .utf8) else {
            throw FormatterRuntimeBackendError.invalidUTF8
        }
        let generationEnd = clock.now
        metricsLock.lock()
        storedMetrics = LlamaGenerationMetrics(
            promptTokenCount: promptTokens.count,
            generatedTokenCount: generatedTokenCount,
            promptMilliseconds: elapsedMilliseconds(
                from: promptStart,
                to: promptEnd
            ),
            generationMilliseconds: elapsedMilliseconds(
                from: generationStart,
                to: generationEnd
            )
        )
        metricsLock.unlock()
        return FormatterOutputSanitizer.clean(result)
    }

    func unloadModel(_ model: AnyObject) {
        (model as? LlamaModelHandle)?.releaseModel()
    }

    private func tokenize(
        _ text: String,
        vocabulary: OpaquePointer
    ) throws -> [llama_token] {
        let requiredCount = text.withCString { pointer in
            llama_tokenize(
                vocabulary,
                pointer,
                Int32(text.utf8.count),
                nil,
                0,
                true,
                true
            )
        }
        guard requiredCount < 0, requiredCount != Int32.min else {
            throw FormatterRuntimeBackendError.tokenizationFailed
        }
        var tokens = [llama_token](repeating: 0, count: Int(-requiredCount))
        let tokenCount = text.withCString { pointer in
            tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(
                    vocabulary,
                    pointer,
                    Int32(text.utf8.count),
                    buffer.baseAddress,
                    Int32(buffer.count),
                    true,
                    true
                )
            }
        }
        guard tokenCount >= 0 else {
            throw FormatterRuntimeBackendError.tokenizationFailed
        }
        return Array(tokens.prefix(Int(tokenCount)))
    }

    private func applyChatTemplate(
        userMessage: String,
        model: OpaquePointer
    ) throws -> String {
        guard let template = llama_model_chat_template(model, nil) else {
            return gemmaChatPrompt(userMessage: userMessage)
        }
        return try "user".withCString { rolePointer in
            try userMessage.withCString { contentPointer in
                var message = llama_chat_message(
                    role: rolePointer,
                    content: contentPointer
                )
                var buffer = [CChar](repeating: 0, count: max(1_024, userMessage.utf8.count * 2))
                var byteCount = buffer.withUnsafeMutableBufferPointer {
                    llama_chat_apply_template(
                        template,
                        &message,
                        1,
                        true,
                        $0.baseAddress,
                        Int32($0.count)
                    )
                }
                if byteCount > buffer.count {
                    buffer = [CChar](repeating: 0, count: Int(byteCount))
                    byteCount = buffer.withUnsafeMutableBufferPointer {
                        llama_chat_apply_template(
                            template,
                            &message,
                            1,
                            true,
                            $0.baseAddress,
                            Int32($0.count)
                        )
                    }
                }
                guard byteCount >= 0 else {
                    return gemmaChatPrompt(userMessage: userMessage)
                }
                return String(
                    decoding: buffer.prefix(Int(byteCount)).map(UInt8.init(bitPattern:)),
                    as: UTF8.self
                )
            }
        }
    }

    private func gemmaChatPrompt(userMessage: String) -> String {
        "<start_of_turn>user\n\(userMessage)<end_of_turn>\n<start_of_turn>model\n"
    }

    private func piece(
        for token: llama_token,
        vocabulary: OpaquePointer
    ) throws -> Data {
        var buffer = [CChar](repeating: 0, count: 256)
        var byteCount = buffer.withUnsafeMutableBufferPointer {
            llama_token_to_piece(
                vocabulary,
                token,
                $0.baseAddress,
                Int32($0.count),
                0,
                false
            )
        }
        if byteCount < 0 {
            buffer = [CChar](repeating: 0, count: Int(-byteCount))
            byteCount = buffer.withUnsafeMutableBufferPointer {
                llama_token_to_piece(
                    vocabulary,
                    token,
                    $0.baseAddress,
                    Int32($0.count),
                    0,
                    false
                )
            }
        }
        guard byteCount >= 0 else {
            throw FormatterRuntimeBackendError.tokenConversionFailed
        }
        return buffer.withUnsafeBytes { rawBuffer in
            Data(rawBuffer.prefix(Int(byteCount)))
        }
    }

    private func elapsedMilliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let components = start.duration(to: end).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

enum FormatterOutputSanitizer {
    private static let controlTokens = [
        "<bos>",
        "<eos>",
        "<start_of_turn>",
        "<end_of_turn>",
        "<start_of_image>",
        "<end_of_image>",
        "<|begin_of_text|>",
        "<|end_of_text|>",
        "<|eot_id|>",
    ]

    static func clean(_ text: String) -> String {
        controlTokens.reduce(text) { partialResult, token in
            partialResult.replacingOccurrences(of: token, with: "")
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class LlamaModelHandle {
    fileprivate private(set) var model: OpaquePointer?

    init(model: OpaquePointer) {
        self.model = model
    }

    func releaseModel() {
        guard let model else { return }
        self.model = nil
        llama_model_free(model)
    }

    deinit {
        releaseModel()
    }
}
