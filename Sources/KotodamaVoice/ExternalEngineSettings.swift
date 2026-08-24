import Foundation
import OSLog
import Observation

enum ExternalEngineKind: String, Codable, CaseIterable, Sendable {
  case openAIAudioTranscriptions
  case whisperCppInference
  case responses
  case chatCompletions
}

struct ExternalEngineConfiguration: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let kind: ExternalEngineKind
  let endpointURL: URL
  let model: String
  let timeout: TimeInterval
  fileprivate(set) var apiKeyReference: APIKeyReference?

  init(
    id: UUID,
    kind: ExternalEngineKind,
    endpointURL: URL,
    model: String,
    timeout: TimeInterval,
    apiKeyReference: APIKeyReference? = nil
  ) {
    self.id = id
    self.kind = kind
    self.endpointURL = endpointURL
    self.model = model
    self.timeout = timeout
    self.apiKeyReference = apiKeyReference
  }
}

enum ExternalEngineSettingsEvent: Equatable, Sendable {
  case saved(id: UUID, hasAPIKey: Bool)
  case removed(id: UUID)
  case loadFailed
}

protocol ExternalEngineSettingsLogging: Sendable {
  func record(_ event: ExternalEngineSettingsEvent)
}

struct OSLogExternalEngineSettingsLogger: ExternalEngineSettingsLogging {
  private let logger = Logger(
    subsystem: "jp.tsuyuki.KotodamaVoice",
    category: "network"
  )

  func record(_ event: ExternalEngineSettingsEvent) {
    switch event {
    case .saved(let id, let hasAPIKey):
      logger.info(
        "external_engine_settings saved id=\(id.uuidString, privacy: .public) has_api_key=\(hasAPIKey, privacy: .public)"
      )
    case .removed(let id):
      logger.info(
        "external_engine_settings removed id=\(id.uuidString, privacy: .public)"
      )
    case .loadFailed:
      logger.error("external_engine_settings load_failed")
    }
  }
}

struct NoopExternalEngineSettingsLogger: ExternalEngineSettingsLogging {
  func record(_ event: ExternalEngineSettingsEvent) {}
}

@Observable
@MainActor
final class ExternalEngineSettingsStore {
  private(set) var configurations: [ExternalEngineConfiguration]

  @ObservationIgnored
  private let defaults: UserDefaults
  @ObservationIgnored
  private let apiKeys: any APIKeyStoring
  @ObservationIgnored
  private let logger: any ExternalEngineSettingsLogging

  private static let configurationsKey = "externalEngine.configurations"

  init(
    defaults: UserDefaults = .standard,
    apiKeys: any APIKeyStoring = KeychainAPIKeyStore(),
    logger: any ExternalEngineSettingsLogging = OSLogExternalEngineSettingsLogger()
  ) {
    self.defaults = defaults
    self.apiKeys = apiKeys
    self.logger = logger
    guard let data = defaults.data(forKey: Self.configurationsKey) else {
      configurations = []
      return
    }
    do {
      configurations = try JSONDecoder().decode(
        [ExternalEngineConfiguration].self,
        from: data
      )
    } catch {
      configurations = []
      logger.record(.loadFailed)
    }
  }

  func save(
    _ configuration: ExternalEngineConfiguration,
    apiKey: String? = nil
  ) throws {
    var savedConfiguration = configuration
    let existing = configurations.first { $0.id == configuration.id }

    if let apiKey {
      if apiKey.isEmpty {
        if let reference = existing?.apiKeyReference
          ?? configuration.apiKeyReference
        {
          try apiKeys.delete(reference)
        }
        savedConfiguration.apiKeyReference = nil
      } else {
        let reference =
          existing?.apiKeyReference
          ?? configuration.apiKeyReference
          ?? APIKeyReference(rawValue: configuration.id.uuidString)
        try apiKeys.save(apiKey, for: reference)
        savedConfiguration.apiKeyReference = reference
      }
    } else {
      savedConfiguration.apiKeyReference =
        existing?.apiKeyReference
        ?? configuration.apiKeyReference
    }

    var updated = configurations.filter { $0.id != configuration.id }
    updated.append(savedConfiguration)
    updated.sort { $0.id.uuidString < $1.id.uuidString }
    try persist(updated)
    configurations = updated
    logger.record(
      .saved(
        id: configuration.id,
        hasAPIKey: savedConfiguration.apiKeyReference != nil
      )
    )
  }

  func apiKey(for id: UUID) throws -> String? {
    guard
      let reference = configurations.first(where: { $0.id == id })?
        .apiKeyReference
    else {
      return nil
    }
    return try apiKeys.read(reference)
  }

  func remove(id: UUID) throws {
    guard let existing = configurations.first(where: { $0.id == id }) else {
      return
    }
    if let reference = existing.apiKeyReference {
      try apiKeys.delete(reference)
    }
    let updated = configurations.filter { $0.id != id }
    try persist(updated)
    configurations = updated
    logger.record(.removed(id: id))
  }

  func export() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(configurations)
  }

  private func persist(_ configurations: [ExternalEngineConfiguration]) throws {
    defaults.set(try JSONEncoder().encode(configurations), forKey: Self.configurationsKey)
  }
}
