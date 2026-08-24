import Foundation
import Testing

@testable import KotodamaVoice

@Suite(.serialized)
struct ExternalEngineSettingsTests {
  @Test
  func keychainAPIKeyRoundTripsUpdatesAndDeletes() throws {
    let store = KeychainAPIKeyStore(
      service: "jp.tsuyuki.KotodamaVoice.Tests.\(UUID().uuidString)"
    )
    let reference = APIKeyReference(rawValue: UUID().uuidString)
    defer { try? store.delete(reference) }

    #expect(try store.read(reference) == nil)
    try store.save("first-secret", for: reference)
    #expect(try store.read(reference) == "first-secret")

    try store.save("updated-secret", for: reference)
    #expect(try store.read(reference) == "updated-secret")

    try store.delete(reference)
    #expect(try store.read(reference) == nil)
  }

  @Test @MainActor
  func APIKeyIsExcludedFromDefaultsExportAndDiagnosticEvents() throws {
    let suiteName = "jp.tsuyuki.KotodamaVoiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let apiKeys = APIKeyStoreSpy()
    let logger = ExternalEngineSettingsLoggerSpy()
    let store = ExternalEngineSettingsStore(
      defaults: defaults,
      apiKeys: apiKeys,
      logger: logger
    )
    let secret = "kv-canary-\(UUID().uuidString)"
    let configuration = ExternalEngineConfiguration(
      id: UUID(),
      kind: .openAIAudioTranscriptions,
      endpointURL: try #require(
        URL(string: "https://speech.example.com/v1/audio/transcriptions")
      ),
      model: "speech-model",
      timeout: 30
    )

    try store.save(configuration, apiKey: secret)
    let saved = try #require(store.configurations.first)
    let reference = try #require(saved.apiKeyReference)

    #expect(try store.apiKey(for: saved.id) == secret)
    #expect(apiKeys.values[reference] == secret)
    #expect(!persistentDomain(defaults, suiteName: suiteName, contains: secret))
    #expect(!String(decoding: try store.export(), as: UTF8.self).contains(secret))
    #expect(!String(describing: logger.events).contains(secret))
    #expect(!logger.events.map(\.osLogMessage).joined().contains(secret))

    let restored = ExternalEngineSettingsStore(
      defaults: defaults,
      apiKeys: apiKeys
    )
    #expect(restored.configurations == store.configurations)
    #expect(try restored.apiKey(for: saved.id) == secret)
  }

  @Test @MainActor
  func removingConfigurationDeletesItsKeychainItem() throws {
    let suiteName = "jp.tsuyuki.KotodamaVoiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let apiKeys = APIKeyStoreSpy()
    let store = ExternalEngineSettingsStore(
      defaults: defaults,
      apiKeys: apiKeys
    )
    let configuration = ExternalEngineConfiguration(
      id: UUID(),
      kind: .responses,
      endpointURL: try #require(
        URL(string: "https://formatter.example.com/v1/responses")
      ),
      model: "formatter-model",
      timeout: 45
    )

    try store.save(configuration, apiKey: "delete-me")
    let reference = try #require(store.configurations.first?.apiKeyReference)
    try store.remove(id: configuration.id)

    #expect(store.configurations.isEmpty)
    #expect(apiKeys.values[reference] == nil)
    #expect(apiKeys.deletedReferences == [reference])
  }

  private func persistentDomain(
    _ defaults: UserDefaults,
    suiteName: String,
    contains secret: String
  ) -> Bool {
    value(defaults.persistentDomain(forName: suiteName) ?? [:], contains: secret)
  }

  private func value(_ value: Any, contains secret: String) -> Bool {
    switch value {
    case let string as String:
      string.contains(secret)
    case let data as Data:
      String(decoding: data, as: UTF8.self).contains(secret)
    case let dictionary as [String: Any]:
      dictionary.contains { key, value in
        key.contains(secret) || self.value(value, contains: secret)
      }
    case let array as [Any]:
      array.contains { self.value($0, contains: secret) }
    default:
      String(describing: value).contains(secret)
    }
  }
}

private final class APIKeyStoreSpy: APIKeyStoring, @unchecked Sendable {
  private(set) var values: [APIKeyReference: String] = [:]
  private(set) var deletedReferences: [APIKeyReference] = []

  func save(_ apiKey: String, for reference: APIKeyReference) throws {
    values[reference] = apiKey
  }

  func read(_ reference: APIKeyReference) throws -> String? {
    values[reference]
  }

  func delete(_ reference: APIKeyReference) throws {
    values[reference] = nil
    deletedReferences.append(reference)
  }
}

private final class ExternalEngineSettingsLoggerSpy: ExternalEngineSettingsLogging,
  @unchecked Sendable
{
  private(set) var events: [ExternalEngineSettingsEvent] = []

  func record(_ event: ExternalEngineSettingsEvent) {
    events.append(event)
  }
}
