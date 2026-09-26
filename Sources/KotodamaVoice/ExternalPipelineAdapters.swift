import Foundation
import KotodamaCore

enum ExternalSpeechPipelineAdapter: Sendable {
  case openAI(OpenAIAudioTranscriptionsAdapter)
  case whisperCpp(WhisperCppInferenceAdapter)

  func transcribe(_ audio: ExternalSpeechAudio) async throws -> String {
    switch self {
    case .openAI(let adapter):
      try await adapter.transcribe(audio)
    case .whisperCpp(let adapter):
      try await adapter.transcribe(audio)
    }
  }
}

enum ExternalSpeechInputError: Error, Equatable {
  case invalidAudio
}

enum ExternalEngineRuntimeError: Error, Equatable {
  case notConfigured(ExternalEndpointPurpose)
  case incompatibleEngineKind
}

@MainActor
final class SelectedSpeechTranscriber: SpeechTranscribing {
  private let settings: SpeechSettingsStore
  private let builtIn: SpeechTranscribing
  private let external: SpeechTranscribing

  init(
    settings: SpeechSettingsStore,
    builtIn: SpeechTranscribing,
    external: SpeechTranscribing
  ) {
    self.settings = settings
    self.builtIn = builtIn
    self.external = external
  }

  func transcribe(
    modelID: String,
    audioInput: WorkerAudioInput,
    requestID: PipelineRequestID
  ) async throws -> String {
    let selected = settings.engine == .builtIn ? builtIn : external
    return try await selected.transcribe(
      modelID: modelID,
      audioInput: audioInput,
      requestID: requestID
    )
  }
  var glossaryEngine: String { settings.engine.rawValue }
  func transcribe(
    modelID: String, audioInput: WorkerAudioInput, requestID: PipelineRequestID,
    hints: [SpeechGlossaryHint]
  ) async throws -> SpeechGlossaryResult {
    if settings.engine == .builtIn {
      return try await builtIn.transcribe(
        modelID: modelID, audioInput: audioInput, requestID: requestID, hints: hints)
    }
    return SpeechGlossaryResult(
      text: try await external.transcribe(
        modelID: modelID, audioInput: audioInput, requestID: requestID))
  }

}

@MainActor
final class ConfiguredExternalSpeechTranscriber: SpeechTranscribing {
  private let settings: ExternalEngineSettingsStore

  init(settings: ExternalEngineSettingsStore) {
    self.settings = settings
  }

  func transcribe(
    modelID _: String,
    audioInput: WorkerAudioInput,
    requestID: PipelineRequestID
  ) async throws -> String {
    guard let configuration = settings.configuration(for: .speech) else {
      throw ExternalEngineRuntimeError.notConfigured(.speech)
    }
    let apiKey = try settings.apiKey(for: configuration.id)
    let confirmation = confirmation(for: configuration)
    let adapter: ExternalSpeechPipelineAdapter
    switch configuration.kind {
    case .openAIAudioTranscriptions:
      adapter = .openAI(
        OpenAIAudioTranscriptionsAdapter(
          endpointURL: configuration.endpointURL,
          model: configuration.model,
          apiKey: apiKey,
          confirmation: confirmation,
          timeout: configuration.timeout
        )
      )
    case .whisperCppInference:
      adapter = .whisperCpp(
        WhisperCppInferenceAdapter(
          endpointURL: configuration.endpointURL,
          confirmation: confirmation,
          timeout: configuration.timeout
        )
      )
    case .responses, .chatCompletions:
      throw ExternalEngineRuntimeError.incompatibleEngineKind
    }
    return try await ExternalSpeechTranscriber(adapter: adapter).transcribe(
      modelID: "",
      audioInput: audioInput,
      requestID: requestID
    )
  }
}

@MainActor
final class ExternalSpeechTranscriber: SpeechTranscribing {
  private let adapter: ExternalSpeechPipelineAdapter

  init(adapter: ExternalSpeechPipelineAdapter) {
    self.adapter = adapter
  }

  func transcribe(
    modelID _: String,
    audioInput: WorkerAudioInput,
    requestID: PipelineRequestID
  ) async throws -> String {
    let waveData = try WaveAudioEncoder.encode(audioInput)
    return try await adapter.transcribe(
      ExternalSpeechAudio(
        data: waveData,
        fileName: "\(requestID.rawValue.uuidString).wav",
        contentType: "audio/wav"
      )
    )
  }
}

enum ExternalFormatterPipelineAdapter: Sendable {
  case responses(OpenAIResponsesFormatterAdapter)
  case chatCompletions(ChatCompletionsFormatterAdapter)

  func format(text: String, prompt: String) async throws -> String {
    switch self {
    case .responses(let adapter):
      try await adapter.format(text: text, prompt: prompt)
    case .chatCompletions(let adapter):
      try await adapter.format(text: text, prompt: prompt)
    }
  }
}

@MainActor
final class ExternalTextFormatter: TextFormatting {
  private let adapter: ExternalFormatterPipelineAdapter
  private let prompt: () -> String

  init(
    adapter: ExternalFormatterPipelineAdapter,
    prompt: @escaping () -> String
  ) {
    self.adapter = adapter
    self.prompt = prompt
  }

  func format(
    _ text: String,
    requestID _: PipelineRequestID
  ) async throws -> String {
    try await format(text, requestID: PipelineRequestID(), glossary: [])
  }

  func format(_ text: String, requestID: PipelineRequestID, glossary: [GlossaryEntry]) async throws
    -> String
  {
    try await adapter.format(
      text: text, prompt: GlossaryPrompt.compose(base: prompt(), entries: glossary))

  }
}

@MainActor
final class ConfiguredExternalTextFormatter: TextFormatting {
  private let settings: ExternalEngineSettingsStore
  private let prompt: () -> String

  init(
    settings: ExternalEngineSettingsStore,
    prompt: @escaping () -> String
  ) {
    self.settings = settings
    self.prompt = prompt
  }

  func format(
    _ text: String,
    requestID _: PipelineRequestID
  ) async throws -> String {
    try await format(text, requestID: PipelineRequestID(), glossary: [])
  }

  func format(_ text: String, requestID: PipelineRequestID, glossary: [GlossaryEntry]) async throws
    -> String
  {
    guard let configuration = settings.configuration(for: .formatter) else {

      throw ExternalEngineRuntimeError.notConfigured(.formatter)
    }
    let apiKey = try settings.apiKey(for: configuration.id)
    let confirmation = confirmation(for: configuration)
    let adapter: ExternalFormatterPipelineAdapter
    switch configuration.kind {
    case .responses:
      adapter = .responses(
        OpenAIResponsesFormatterAdapter(
          endpointURL: configuration.endpointURL,
          model: configuration.model,
          apiKey: apiKey,
          confirmation: confirmation,
          timeout: configuration.timeout
        )
      )
    case .chatCompletions:
      adapter = .chatCompletions(
        ChatCompletionsFormatterAdapter(
          endpointURL: configuration.endpointURL,
          model: configuration.model,
          apiKey: apiKey,
          confirmation: confirmation,
          timeout: configuration.timeout
        )
      )
    case .openAIAudioTranscriptions, .whisperCppInference:
      throw ExternalEngineRuntimeError.incompatibleEngineKind
    }
    return try await adapter.format(
      text: text, prompt: GlossaryPrompt.compose(base: prompt(), entries: glossary))
  }
}

private func confirmation(
  for configuration: ExternalEngineConfiguration
) -> ExternalEndpointConfirmation? {
  guard !configuration.acceptedConfirmations.isEmpty else { return nil }
  return ExternalEndpointConfirmation(
    endpoint: configuration.endpointURL,
    accepted: configuration.acceptedConfirmations
  )
}

private enum WaveAudioEncoder {
  static func encode(_ input: WorkerAudioInput) throws -> Data {
    guard
      input.sampleRate.isFinite,
      input.sampleRate.rounded() == input.sampleRate,
      input.sampleRate > 0,
      input.sampleRate <= Double(UInt32.max),
      input.channelCount > 0,
      input.channelCount <= Int(UInt16.max),
      input.sampleCount >= 0
    else {
      throw ExternalSpeechInputError.invalidAudio
    }

    try input.fileHandle.seek(toOffset: 0)
    let samples = try input.fileHandle.readToEnd() ?? Data()
    let expectedByteCount =
      input.sampleCount
      * Int64(input.channelCount)
      * Int64(MemoryLayout<Float>.size)
    guard
      expectedByteCount == samples.count,
      samples.count <= Int(UInt32.max) - 36
    else {
      throw ExternalSpeechInputError.invalidAudio
    }

    let channelCount = UInt16(input.channelCount)
    let sampleRate = UInt32(input.sampleRate)
    let bitsPerSample: UInt16 = 32
    let blockAlign = channelCount * (bitsPerSample / 8)
    let byteRate = sampleRate * UInt32(blockAlign)

    var result = Data()
    result.reserveCapacity(44 + samples.count)
    result.append(contentsOf: Data("RIFF".utf8))
    append(UInt32(36 + samples.count), to: &result)
    result.append(contentsOf: Data("WAVEfmt ".utf8))
    append(UInt32(16), to: &result)
    append(UInt16(3), to: &result)
    append(channelCount, to: &result)
    append(sampleRate, to: &result)
    append(byteRate, to: &result)
    append(blockAlign, to: &result)
    append(bitsPerSample, to: &result)
    result.append(contentsOf: Data("data".utf8))
    append(UInt32(samples.count), to: &result)
    result.append(samples)
    return result
  }

  private static func append<Value: FixedWidthInteger>(
    _ value: Value,
    to data: inout Data
  ) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { bytes in
      data.append(contentsOf: bytes)
    }
  }
}
