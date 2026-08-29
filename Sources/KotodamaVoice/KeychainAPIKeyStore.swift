import Foundation
import Security

struct APIKeyReference: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String
}

protocol APIKeyStoring: Sendable {
  func save(_ apiKey: String, for reference: APIKeyReference) throws
  func read(_ reference: APIKeyReference) throws -> String?
  func delete(_ reference: APIKeyReference) throws
}

enum KeychainAPIKeyStoreError: Error, Equatable {
  case status(OSStatus)
  case invalidData
}

struct KeychainAPIKeyStore: APIKeyStoring {
  private let service: String

  init(service: String = "com.tsuyukimakoto.KotodamaVoice.external-engine-api-key") {
    self.service = service
  }

  func save(_ apiKey: String, for reference: APIKeyReference) throws {
    let value = Data(apiKey.utf8)
    let status = SecItemUpdate(
      itemQuery(for: reference) as CFDictionary,
      [kSecValueData as String: value] as CFDictionary
    )
    switch status {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var attributes = itemQuery(for: reference)
      attributes[kSecValueData as String] = value
      let addStatus = SecItemAdd(attributes as CFDictionary, nil)
      if addStatus == errSecDuplicateItem {
        let retryStatus = SecItemUpdate(
          itemQuery(for: reference) as CFDictionary,
          [kSecValueData as String: value] as CFDictionary
        )
        try requireSuccess(retryStatus)
      } else {
        try requireSuccess(addStatus)
      }
    default:
      throw KeychainAPIKeyStoreError.status(status)
    }
  }

  func read(_ reference: APIKeyReference) throws -> String? {
    var query = itemQuery(for: reference)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    try requireSuccess(status)
    guard
      let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      throw KeychainAPIKeyStoreError.invalidData
    }
    return value
  }

  func delete(_ reference: APIKeyReference) throws {
    let status = SecItemDelete(itemQuery(for: reference) as CFDictionary)
    guard status != errSecItemNotFound else {
      return
    }
    try requireSuccess(status)
  }

  private func itemQuery(for reference: APIKeyReference) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: reference.rawValue,
    ]
  }

  private func requireSuccess(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
      throw KeychainAPIKeyStoreError.status(status)
    }
  }
}
