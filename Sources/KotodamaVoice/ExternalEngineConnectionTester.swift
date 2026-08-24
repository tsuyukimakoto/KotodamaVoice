import Foundation

enum ExternalEngineConnection: Sendable {
  case openAIAudioTranscriptions(OpenAIAudioTranscriptionsAdapter)
  case whisperCppInference(WhisperCppInferenceAdapter)
  case responses(OpenAIResponsesFormatterAdapter)
  case chatCompletions(ChatCompletionsFormatterAdapter)
}

enum ExternalEngineConnectionFailure: Equatable, Sendable {
  case contractMismatch
  case serverRejected(statusCode: Int)
  case transport
}

enum ExternalEngineConnectionTestResult: Equatable, Sendable {
  case ready
  case notReady(ExternalEngineConnectionFailure)
}

struct ExternalEngineConnectionTester: Sendable {
  func test(
    _ engine: ExternalEngineConnection
  ) async -> ExternalEngineConnectionTestResult {
    do {
      switch engine {
      case .openAIAudioTranscriptions(let adapter):
        _ = try await adapter.transcribe(Self.probeAudio)
      case .whisperCppInference(let adapter):
        _ = try await adapter.transcribe(Self.probeAudio)
      case .responses(let adapter):
        _ = try await adapter.format(
          text: Self.probeText,
          prompt: Self.probePrompt
        )
      case .chatCompletions(let adapter):
        _ = try await adapter.format(
          text: Self.probeText,
          prompt: Self.probePrompt
        )
      }
      return .ready
    } catch let error as ExternalSpeechAdapterError {
      return .notReady(failure(for: error))
    } catch let error as ExternalFormatterAdapterError {
      return .notReady(failure(for: error))
    } catch {
      return .notReady(.transport)
    }
  }

  private func failure(
    for error: ExternalSpeechAdapterError
  ) -> ExternalEngineConnectionFailure {
    switch error {
    case .invalidHTTPResponse, .invalidResponseBody:
      .contractMismatch
    case .unsuccessfulStatus(let statusCode):
      .serverRejected(statusCode: statusCode)
    }
  }

  private func failure(
    for error: ExternalFormatterAdapterError
  ) -> ExternalEngineConnectionFailure {
    switch error {
    case .invalidHTTPResponse, .invalidResponseBody:
      .contractMismatch
    case .unsuccessfulStatus(let statusCode):
      .serverRejected(statusCode: statusCode)
    }
  }

  private static let probeText = "接続テスト"
  private static let probePrompt = "入力本文だけをそのまま返してください。"
  private static let probeAudio = ExternalSpeechAudio(
    data: Data([
      0x52, 0x49, 0x46, 0x46, 0x26, 0x00, 0x00, 0x00,
      0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20,
      0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
      0x80, 0x3E, 0x00, 0x00, 0x00, 0x7D, 0x00, 0x00,
      0x02, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74, 0x61,
      0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]),
    fileName: "connection-test.wav",
    contentType: "audio/wav"
  )
}
