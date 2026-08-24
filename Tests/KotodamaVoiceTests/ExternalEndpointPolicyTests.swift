import Foundation
import Testing

@testable import KotodamaVoice

@Test(arguments: [
  "http://localhost:1234/v1/responses",
  "http://LOCALHOST.:1234/inference",
  "http://127.0.0.1:8080/inference",
  "http://127.255.255.254:8080/inference",
  "http://[::1]:8080/inference",
  "http://[0:0:0:0:0:0:0:1]:8080/inference",
])
func loopbackEndpointsDoNotRequireExternalTransmissionConfirmation(
  urlString: String
) throws {
  let assessment = try ExternalEndpointPolicy.assess(
    try #require(URL(string: urlString)),
    purpose: .speech
  )

  #expect(assessment.isLoopback)
  #expect(assessment.requiredConfirmations.isEmpty)
  #expect(assessment.permitsUse(with: nil))
}

@Test(arguments: [
  "https://example.com/v1/responses",
  "https://localhost.example.com/v1/responses",
  "https://192.168.1.10/v1/responses",
  "https://128.0.0.1/v1/responses",
  "https://[::2]/v1/responses",
])
func externalEndpointsRequireTransmissionConfirmation(
  urlString: String
) throws {
  let endpoint = try #require(URL(string: urlString))
  let assessment = try ExternalEndpointPolicy.assess(
    endpoint,
    purpose: .formatter
  )

  #expect(!assessment.isLoopback)
  #expect(assessment.payloads == [.transcription, .prompt])
  #expect(assessment.requiredConfirmations == [.externalTransmission])
  #expect(!assessment.permitsUse(with: nil))
  #expect(
    assessment.permitsUse(
      with: ExternalEndpointConfirmation(
        endpoint: endpoint,
        accepted: [.externalTransmission]
      )))
}

@Test
func externalPlainHTTPRequiresASeparateUnencryptedTransportConfirmation() throws {
  let endpoint = try #require(
    URL(string: "http://api.example.com/v1/audio/transcriptions")
  )
  let assessment = try ExternalEndpointPolicy.assess(
    endpoint,
    purpose: .speech
  )

  #expect(assessment.payloads == [.audio])
  #expect(
    assessment.requiredConfirmations == [
      .externalTransmission,
      .unencryptedHTTP,
    ])
  #expect(
    !assessment.permitsUse(
      with: ExternalEndpointConfirmation(
        endpoint: endpoint,
        accepted: [.externalTransmission]
      )))
  #expect(
    assessment.permitsUse(
      with: ExternalEndpointConfirmation(
        endpoint: endpoint,
        accepted: [.externalTransmission, .unencryptedHTTP]
      )))
}

@Test
func confirmationIsBoundToTheExactEndpoint() throws {
  let endpoint = try #require(URL(string: "https://api.example.com/v1/responses"))
  let assessment = try ExternalEndpointPolicy.assess(
    endpoint,
    purpose: .formatter
  )
  let otherEndpointConfirmation = ExternalEndpointConfirmation(
    endpoint: try #require(URL(string: "https://other.example.com/v1/responses")),
    accepted: [.externalTransmission]
  )

  #expect(!assessment.permitsUse(with: otherEndpointConfirmation))
}

@Test(arguments: [
  "ftp://example.com/inference",
  "file:///tmp/inference",
])
func unsupportedOrHostlessEndpointsAreRejected(urlString: String) throws {
  let endpoint = try #require(URL(string: urlString))

  #expect(throws: ExternalEndpointPolicyError.invalidEndpoint) {
    _ = try ExternalEndpointPolicy.assess(endpoint, purpose: .speech)
  }
}

@Test
func externalSpeechRequestIsNotSentBeforeConfirmation() async throws {
  let endpoint = try #require(
    URL(string: "https://speech.example.com/v1/audio/transcriptions")
  )
  let session = ExternalEndpointRecordingURLProtocol.session()
  ExternalEndpointRecordingURLProtocol.reset()

  await #expect(
    throws: ExternalEndpointPolicyError.confirmationRequired([
      .externalTransmission
    ])
  ) {
    _ = try await OpenAIAudioTranscriptionsAdapter(
      endpointURL: endpoint,
      model: "test-model",
      session: session
    ).transcribe(.policyFixture)
  }

  #expect(ExternalEndpointRecordingURLProtocol.requestCount == 0)
}

@Test
func externalFormatterRequestIsSentOnlyAfterExactConfirmation() async throws {
  let endpoint = try #require(
    URL(string: "https://formatter.example.com/v1/responses")
  )
  let session = ExternalEndpointRecordingURLProtocol.session()
  ExternalEndpointRecordingURLProtocol.reset()

  let adapter = OpenAIResponsesFormatterAdapter(
    endpointURL: endpoint,
    model: "test-model",
    confirmation: ExternalEndpointConfirmation(
      endpoint: endpoint,
      accepted: [.externalTransmission]
    ),
    session: session
  )
  let output = try await adapter.format(text: "原文", prompt: "指示")

  #expect(output == "整形結果")
  #expect(ExternalEndpointRecordingURLProtocol.requestCount == 1)
}

extension ExternalSpeechAudio {
  fileprivate static let policyFixture = ExternalSpeechAudio(
    data: Data("audio".utf8),
    fileName: "recording.wav",
    contentType: "audio/wav"
  )
}

private final class ExternalEndpointRecordingURLProtocol: URLProtocol,
  @unchecked Sendable
{
  private static let lock = NSLock()
  nonisolated(unsafe) private static var recordedRequestCount = 0

  static var requestCount: Int {
    lock.withLock { recordedRequestCount }
  }

  static func reset() {
    lock.withLock { recordedRequestCount = 0 }
  }

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ExternalEndpointRecordingURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.lock.withLock { Self.recordedRequestCount += 1 }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    let body = Data(
      #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"整形結果"}]}]}"#
        .utf8
    )
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
