import Foundation
import Network
import Testing

@testable import KotodamaVoice

@Test(arguments: ConnectionFixtureKind.allCases)
func connectionTestUsesTheSelectedEngineContract(
  kind: ConnectionFixtureKind
) async throws {
  let server = try ConnectionFixtureServer(responseBody: kind.validResponse)
  let tester = ExternalEngineConnectionTester()

  let result = await tester.test(kind.engine(server: server))

  #expect(result == .ready)
}

@Test(arguments: ConnectionFixtureKind.allCases)
func tcpAndHTTPAvailabilityWithoutTheSelectedContractIsNotReady(
  kind: ConnectionFixtureKind
) async throws {
  let server = try ConnectionFixtureServer(
    responseBody: Data(#"{"ok":true}"#.utf8)
  )
  let tester = ExternalEngineConnectionTester()

  let result = await tester.test(kind.engine(server: server))

  #expect(result == .notReady(.contractMismatch))
}

enum ConnectionFixtureKind: CaseIterable, Sendable {
  case openAIAudioTranscriptions
  case whisperCppInference
  case responses
  case chatCompletions

  var validResponse: Data {
    switch self {
    case .openAIAudioTranscriptions, .whisperCppInference:
      Data(#"{"text":"接続確認"}"#.utf8)
    case .responses:
      Data(
        #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"接続確認"}]}]}"#
          .utf8)
    case .chatCompletions:
      Data(
        #"{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"接続確認"}}]}"#
          .utf8)
    }
  }

  fileprivate func engine(
    server: ConnectionFixtureServer
  ) -> ExternalEngineConnection {
    switch self {
    case .openAIAudioTranscriptions:
      .openAIAudioTranscriptions(
        OpenAIAudioTranscriptionsAdapter(
          endpointURL: server.url(path: "/v1/audio/transcriptions"),
          model: "fixture-model"
        )
      )
    case .whisperCppInference:
      .whisperCppInference(
        WhisperCppInferenceAdapter(
          endpointURL: server.url(path: "/inference")
        )
      )
    case .responses:
      .responses(
        OpenAIResponsesFormatterAdapter(
          endpointURL: server.url(path: "/v1/responses"),
          model: "fixture-model"
        )
      )
    case .chatCompletions:
      .chatCompletions(
        ChatCompletionsFormatterAdapter(
          endpointURL: server.url(path: "/v1/chat/completions"),
          model: "fixture-model"
        )
      )
    }
  }
}

private final class ConnectionFixtureServer: @unchecked Sendable {
  private let responseBody: Data
  private let listener: NWListener
  private let queue = DispatchQueue(label: "ConnectionFixtureServer")

  init(responseBody: Data) throws {
    self.responseBody = responseBody
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.receiveRequest(on: connection)
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

  func url(path: String) -> URL {
    URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
  }

  private func receiveRequest(on connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] _, _, _, _ in
      guard let self else { return }
      let headers = [
        "HTTP/1.1 200 OK",
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
        completion: .contentProcessed { _ in connection.cancel() }
      )
    }
  }
}
