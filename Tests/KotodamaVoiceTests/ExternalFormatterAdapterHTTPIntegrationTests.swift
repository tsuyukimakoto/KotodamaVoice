import Foundation
import KotodamaCore
import Network
import Testing

@testable import KotodamaVoice

@Test @MainActor
func configuredExternalFormatterUsesSavedConfigurationAndAPIKey() async throws {
  let server = try FormatterAdapterFixtureServer(
    responseBody: Data(
      #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"設定経由の整形結果"}]}]}"#
        .utf8
    )
  )
  let suiteName = "ConfiguredExternalFormatterTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let apiKeys = FormatterAPIKeyStoreSpy()
  let settings = ExternalEngineSettingsStore(
    defaults: defaults,
    apiKeys: apiKeys
  )
  let configuration = ExternalEngineConfiguration(
    id: UUID(),
    kind: .responses,
    endpointURL: server.url(path: "/v1/responses"),
    model: "configured-model",
    timeout: 2
  )
  try settings.save(configuration, apiKey: "configured-secret")
  let formatter = ConfiguredExternalTextFormatter(
    settings: settings,
    prompt: { "configured-prompt" }
  )

  let output = try await formatter.format(
    "configured-input",
    requestID: PipelineRequestID()
  )
  let request = try #require(server.receivedRequest)
  let body = try #require(
    JSONSerialization.jsonObject(with: request.body) as? [String: Any]
  )

  #expect(output == "設定経由の整形結果")
  #expect(request.headers["authorization"] == "Bearer configured-secret")
  #expect(body["model"] as? String == "configured-model")
  #expect(body["instructions"] as? String == "configured-prompt")
  #expect(body["input"] as? String == "configured-input")
}

@Test @MainActor
func configuredExternalFormatterTimeoutReturnsOriginalText() async throws {
  let server = try FormatterAdapterFixtureServer(
    responseBody: Data(
      #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"遅すぎる結果"}]}]}"#
        .utf8
    ),
    responseDelayMilliseconds: 500
  )
  let suiteName = "ConfiguredExternalTimeoutTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let settings = ExternalEngineSettingsStore(
    defaults: defaults,
    apiKeys: FormatterAPIKeyStoreSpy()
  )
  try settings.save(
    ExternalEngineConfiguration(
      id: UUID(),
      kind: .responses,
      endpointURL: server.url(path: "/v1/responses"),
      model: "configured-model",
      timeout: 0.05
    )
  )
  let requestID = PipelineRequestID()
  let pipeline = TextFormattingPipeline(
    coordinator: PipelineCoordinator(
      store: PipelineStore(initialState: .transcribing(requestID))
    ),
    settings: FormatterSettingsStore(engine: .external),
    builtIn: UnavailableTextFormatter(),
    external: ConfiguredExternalTextFormatter(
      settings: settings,
      prompt: { "prompt" }
    )
  )

  let output = try await pipeline.process(
    LocalTranscription(requestID: requestID, text: "timeout原文")
  )

  #expect(output == FormattingOutput(text: "timeout原文", usedFallback: true))
  #expect(server.receivedRequest != nil)
}

@Test
func responsesFormatterAdapterUsesLMStudioResponseContract() async throws {
  let server = try FormatterAdapterFixtureServer(
    responseBody: Data(
      #"""
      {
        "object":"response",
        "status":"completed",
        "output":[
          {"type":"reasoning","summary":[]},
          {"type":"message","role":"assistant","content":[
            {"type":"output_text","text":"LM Studio整形結果","annotations":[]}
          ]}
        ]
      }
      """#.utf8))
  let adapter = OpenAIResponsesFormatterAdapter(
    endpointURL: server.url(path: "/v1/responses"),
    model: "local-model",
    apiKey: "fixture-secret"
  )

  let text = try await adapter.format(
    text: "文字起こし原文",
    prompt: "整形指示"
  )
  let request = try #require(server.receivedRequest)
  let body = try #require(
    JSONSerialization.jsonObject(with: request.body) as? [String: Any]
  )

  #expect(text == "LM Studio整形結果")
  #expect(request.requestLine == "POST /v1/responses HTTP/1.1")
  #expect(request.headers["authorization"] == "Bearer fixture-secret")
  #expect(request.headers["content-type"] == "application/json")
  #expect(body["model"] as? String == "local-model")
  #expect(body["instructions"] as? String == "整形指示")
  #expect(body["input"] as? String == "文字起こし原文")
  #expect(body["store"] as? Bool == false)
}

@Test
func chatCompletionsFormatterAdapterUsesLlamaServerContract() async throws {
  let server = try FormatterAdapterFixtureServer(
    responseBody: Data(
      #"""
      {
        "object":"chat.completion",
        "choices":[
          {"index":0,"finish_reason":"stop","message":{
            "role":"assistant","content":"llama-server整形結果"
          }}
        ]
      }
      """#.utf8))
  let adapter = ChatCompletionsFormatterAdapter(
    endpointURL: server.url(path: "/v1/chat/completions"),
    model: "local-model"
  )

  let text = try await adapter.format(
    text: "文字起こし原文",
    prompt: "整形指示"
  )
  let request = try #require(server.receivedRequest)
  let body = try #require(
    JSONSerialization.jsonObject(with: request.body) as? [String: Any]
  )
  let messages = try #require(body["messages"] as? [[String: String]])

  #expect(text == "llama-server整形結果")
  #expect(request.requestLine == "POST /v1/chat/completions HTTP/1.1")
  #expect(request.headers["authorization"] == nil)
  #expect(body["model"] as? String == "local-model")
  #expect(body["stream"] as? Bool == false)
  #expect(
    messages == [
      ["role": "system", "content": "整形指示"],
      ["role": "user", "content": "文字起こし原文"],
    ])
}

@Test(arguments: ExternalFormatterFixtureKind.allCases)
func externalFormatterAdaptersRejectTheOtherResponseContract(
  kind: ExternalFormatterFixtureKind
) async throws {
  let response: String
  switch kind {
  case .responses:
    response = #"{"choices":[{"message":{"content":"契約違い"}}]}"#
  case .chatCompletions:
    response =
      #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"契約違い"}]}]}"#
  }
  let server = try FormatterAdapterFixtureServer(
    responseBody: Data(response.utf8)
  )

  await #expect(throws: ExternalFormatterAdapterError.invalidResponseBody) {
    switch kind {
    case .responses:
      _ = try await OpenAIResponsesFormatterAdapter(
        endpointURL: server.url(path: "/v1/responses"),
        model: "local-model"
      ).format(text: "原文", prompt: "指示")
    case .chatCompletions:
      _ = try await ChatCompletionsFormatterAdapter(
        endpointURL: server.url(path: "/v1/chat/completions"),
        model: "local-model"
      ).format(text: "原文", prompt: "指示")
    }
  }
}

@Test @MainActor
func externalFormatterFailureReturnsOriginalWithoutTryingAnotherEndpoint()
  async throws
{
  let failingServer = try FormatterAdapterFixtureServer(
    statusCode: 503,
    responseBody: Data(#"{"error":"unavailable"}"#.utf8)
  )
  let alternateServer = try FormatterAdapterFixtureServer(
    responseBody: Data(
      #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"unexpected fallback"}]}]}"#
        .utf8
    )
  )
  let requestID = PipelineRequestID()
  let store = PipelineStore(initialState: .transcribing(requestID))
  let settings = FormatterSettingsStore(engine: .external)
  let selected = ExternalTextFormatter(
    adapter: .responses(
      OpenAIResponsesFormatterAdapter(
        endpointURL: failingServer.url(path: "/v1/responses"),
        model: "formatter-model"
      )
    ),
    prompt: { "整形指示" }
  )
  let unselected = ExternalTextFormatter(
    adapter: .responses(
      OpenAIResponsesFormatterAdapter(
        endpointURL: alternateServer.url(path: "/v1/responses"),
        model: "alternate-model"
      )
    ),
    prompt: { "使用されない指示" }
  )
  let pipeline = TextFormattingPipeline(
    coordinator: PipelineCoordinator(store: store),
    settings: settings,
    builtIn: unselected,
    external: selected
  )

  let output = try await pipeline.process(
    LocalTranscription(requestID: requestID, text: "文字起こし原文")
  )

  #expect(output == FormattingOutput(text: "文字起こし原文", usedFallback: true))
  let request = try #require(failingServer.receivedRequest)
  let body = try #require(
    JSONSerialization.jsonObject(with: request.body) as? [String: Any]
  )
  #expect(body["input"] as? String == "文字起こし原文")
  #expect(body["instructions"] as? String == "整形指示")
  #expect(alternateServer.receivedRequest == nil)
}

enum ExternalFormatterFixtureKind: CaseIterable, Sendable {
  case responses
  case chatCompletions
}

private struct FormatterReceivedHTTPRequest: Sendable {
  let requestLine: String
  let headers: [String: String]
  let body: Data
}

private final class FormatterAdapterFixtureServer: @unchecked Sendable {
  private let statusCode: Int
  private let responseBody: Data
  private let responseDelayMilliseconds: Int
  private let listener: NWListener
  private let queue = DispatchQueue(label: "FormatterAdapterFixtureServer")
  private let lock = NSLock()
  private var request: FormatterReceivedHTTPRequest?

  init(
    statusCode: Int = 200,
    responseBody: Data,
    responseDelayMilliseconds: Int = 0
  ) throws {
    self.statusCode = statusCode
    self.responseBody = responseBody
    self.responseDelayMilliseconds = responseDelayMilliseconds
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.receive(on: connection, accumulated: Data())
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 3) == .success,
      listener.port != nil
    else {
      listener.cancel()
      throw URLError(.cannotConnectToHost)
    }
  }

  deinit { listener.cancel() }

  var receivedRequest: FormatterReceivedHTTPRequest? {
    lock.lock()
    defer { lock.unlock() }
    return request
  }

  func url(path: String) -> URL {
    URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
  }

  private func receive(on connection: NWConnection, accumulated: Data) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      var completeData = accumulated
      if let data { completeData.append(data) }
      if let request = Self.parseCompleteRequest(completeData) {
        self.store(request)
        self.respond(on: connection)
      } else if !isComplete, error == nil {
        self.receive(on: connection, accumulated: completeData)
      } else {
        connection.cancel()
      }
    }
  }

  private func store(_ request: FormatterReceivedHTTPRequest) {
    lock.lock()
    self.request = request
    lock.unlock()
  }

  private func respond(on connection: NWConnection) {
    guard responseDelayMilliseconds > 0 else {
      sendResponse(on: connection)
      return
    }
    queue.asyncAfter(
      deadline: .now() + .milliseconds(responseDelayMilliseconds)
    ) { [weak self] in
      self?.sendResponse(on: connection)
    }
  }

  private func sendResponse(on connection: NWConnection) {
    let headers = [
      "HTTP/1.1 \(statusCode) \(statusCode == 200 ? "OK" : "Error")",
      "Content-Type: application/json",
      "Content-Length: \(responseBody.count)",
      "Connection: close",
      "",
      "",
    ].joined(separator: "\r\n")
    var response = Data(headers.utf8)
    response.append(responseBody)
    connection.send(
      content: response,
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  }

  private static func parseCompleteRequest(
    _ data: Data
  ) -> FormatterReceivedHTTPRequest? {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: separator) else { return nil }
    let headerText = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...]
        .trimmingCharacters(in: .whitespaces)
    }
    guard let lengthText = headers["content-length"],
      let contentLength = Int(lengthText)
    else { return nil }
    let bodyStart = headerRange.upperBound
    guard data.count >= bodyStart + contentLength else { return nil }
    return FormatterReceivedHTTPRequest(
      requestLine: requestLine,
      headers: headers,
      body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
    )
  }
}

private final class FormatterAPIKeyStoreSpy: APIKeyStoring,
  @unchecked Sendable
{
  private var values: [APIKeyReference: String] = [:]

  func save(_ apiKey: String, for reference: APIKeyReference) throws {
    values[reference] = apiKey
  }

  func read(_ reference: APIKeyReference) throws -> String? {
    values[reference]
  }

  func delete(_ reference: APIKeyReference) throws {
    values[reference] = nil
  }
}

@Test(arguments: [false, true]) @MainActor
func glossaryExternalFormatterOnlySendsApprovedReference(approved: Bool) async throws {
  let server = try FormatterAdapterFixtureServer(
    responseBody: Data(
      #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Codex"}]}]}"#
        .utf8))
  let suite = "com.tsuyukimakoto.GlossaryHTTP.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let external = ExternalEngineSettingsStore(defaults: defaults, apiKeys: FormatterAPIKeyStoreSpy())
  try external.save(
    ExternalEngineConfiguration(
      id: UUID(), kind: .responses, endpointURL: server.url(path: "/v1/responses"),
      model: "fixture", timeout: 2))
  let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let glossary = GlossarySettingsStore(directory: root, defaults: defaults)
  try glossary.save(GlossaryEntry(term: "Codex", reading: "READING", note: "DESCRIPTION"))
  glossary.setFormatting(true)
  let session = GlossarySession(
    settings: glossary, diagnostics: GlossaryDiagnostics(directory: root.appending(path: "logs")))
  session.begin()
  let id = PipelineRequestID()
  let pipeline = TextFormattingPipeline(
    coordinator: PipelineCoordinator(store: PipelineStore(initialState: .transcribing(id))),
    settings: FormatterSettingsStore(engine: .external), builtIn: UnavailableTextFormatter(),
    external: ConfiguredExternalTextFormatter(settings: external, prompt: { "BASE" }),
    glossary: session, permitsExternalGlossary: { approved })
  _ = try await pipeline.process(LocalTranscription(requestID: id, text: "SOURCE"))
  let body = try #require(server.receivedRequest).body
  let text = String(decoding: body, as: UTF8.self)
  #expect(text.contains("READING") == approved)
  #expect(text.contains("DESCRIPTION") == approved)
  #expect(text.contains("BASE") && text.contains("SOURCE"))
}
