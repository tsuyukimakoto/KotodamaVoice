import Darwin
import Foundation

enum ExternalEndpointPurpose: Hashable, Sendable {
  case speech
  case formatter

  fileprivate var payloads: Set<ExternalEndpointPayload> {
    switch self {
    case .speech:
      [.audio]
    case .formatter:
      [.transcription, .prompt]
    }
  }
}

enum ExternalEndpointPayload: Hashable, Sendable {
  case audio
  case transcription
  case prompt
}

enum ExternalEndpointConfirmationRequirement: String, Codable, Hashable, Sendable {
  case externalTransmission
  case unencryptedHTTP
}

struct ExternalEndpointConfirmation: Equatable, Sendable {
  let endpoint: URL
  let accepted: Set<ExternalEndpointConfirmationRequirement>
}

struct ExternalEndpointAssessment: Equatable, Sendable {
  let endpoint: URL
  let isLoopback: Bool
  let payloads: Set<ExternalEndpointPayload>
  let requiredConfirmations: Set<ExternalEndpointConfirmationRequirement>

  func permitsUse(with confirmation: ExternalEndpointConfirmation?) -> Bool {
    guard !requiredConfirmations.isEmpty else {
      return true
    }
    guard let confirmation, confirmation.endpoint == endpoint else {
      return false
    }
    return requiredConfirmations.isSubset(of: confirmation.accepted)
  }
}

enum ExternalEndpointPolicyError: Error, Equatable {
  case invalidEndpoint
  case confirmationRequired(Set<ExternalEndpointConfirmationRequirement>)
}

enum ExternalEndpointPolicy {
  static func requireAuthorization(
    for endpoint: URL,
    purpose: ExternalEndpointPurpose,
    confirmation: ExternalEndpointConfirmation?
  ) throws {
    let assessment = try assess(endpoint, purpose: purpose)
    guard assessment.permitsUse(with: confirmation) else {
      throw ExternalEndpointPolicyError.confirmationRequired(
        assessment.requiredConfirmations
      )
    }
  }

  static func assess(
    _ endpoint: URL,
    purpose: ExternalEndpointPurpose
  ) throws -> ExternalEndpointAssessment {
    guard
      let scheme = endpoint.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = endpoint.host(percentEncoded: false),
      !host.isEmpty
    else {
      throw ExternalEndpointPolicyError.invalidEndpoint
    }

    let isLoopback = LoopbackHost.matches(host)
    var requiredConfirmations: Set<ExternalEndpointConfirmationRequirement> = []
    if !isLoopback {
      requiredConfirmations.insert(.externalTransmission)
      if scheme == "http" {
        requiredConfirmations.insert(.unencryptedHTTP)
      }
    }

    return ExternalEndpointAssessment(
      endpoint: endpoint,
      isLoopback: isLoopback,
      payloads: purpose.payloads,
      requiredConfirmations: requiredConfirmations
    )
  }
}

private enum LoopbackHost {
  static func matches(_ rawHost: String) -> Bool {
    let host = normalize(rawHost)
    return host == "localhost" || isIPv4Loopback(host) || isIPv6Loopback(host)
  }

  private static func normalize(_ rawHost: String) -> String {
    var host = rawHost.lowercased()
    while host.hasSuffix(".") {
      host.removeLast()
    }
    if host.hasPrefix("[") && host.hasSuffix("]") {
      host.removeFirst()
      host.removeLast()
    }
    if let zoneSeparator = host.firstIndex(of: "%") {
      host = String(host[..<zoneSeparator])
    }
    return host
  }

  private static func isIPv4Loopback(_ host: String) -> Bool {
    var address = in_addr()
    let parsed = host.withCString { pointer in
      inet_pton(AF_INET, pointer, &address)
    }
    guard parsed == 1 else {
      return false
    }
    return UInt32(bigEndian: address.s_addr) >> 24 == 127
  }

  private static func isIPv6Loopback(_ host: String) -> Bool {
    var address = in6_addr()
    let parsed = host.withCString { pointer in
      inet_pton(AF_INET6, pointer, &address)
    }
    guard parsed == 1 else {
      return false
    }
    return withUnsafeBytes(of: address) { bytes in
      bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }
  }
}
