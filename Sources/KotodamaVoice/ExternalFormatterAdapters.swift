import Foundation

enum ExternalFormatterAdapterError: Error, Equatable {
  case invalidHTTPResponse
  case unsuccessfulStatus(Int)
  case invalidResponseBody
}

struct OpenAIResponsesFormatterAdapter: Sendable {
  let endpointURL: URL
  let model: String
  let apiKey: String?
  let confirmation: ExternalEndpointConfirmation?
  let timeout: TimeInterval
  private let session: URLSession

  init(
    endpointURL: URL,
    model: String,
    apiKey: String? = nil,
    confirmation: ExternalEndpointConfirmation? = nil,
    timeout: TimeInterval = 60,
    session: URLSession = .shared
  ) {
    self.endpointURL = endpointURL
    self.model = model
    self.apiKey = apiKey
    self.confirmation = confirmation
    self.timeout = timeout
    self.session = session
  }

  func format(text: String, prompt: String) async throws -> String {
    try ExternalEndpointPolicy.requireAuthorization(
      for: endpointURL,
      purpose: .formatter,
      confirmation: confirmation
    )
    let body = RequestBody(
      model: model,
      instructions: prompt,
      input: text,
      store: false
    )
    var request = try ExternalFormatterHTTPRequest.make(
      url: endpointURL,
      body: body,
      apiKey: apiKey
    )
    request.timeoutInterval = timeout
    let response: ResponseBody =
      try await ExternalFormatterHTTPResponse
      .perform(request, session: session)
    guard response.status == "completed" else {
      throw ExternalFormatterAdapterError.invalidResponseBody
    }
    let textParts = response.output.flatMap { item in
      guard item.type == "message", item.role == "assistant" else {
        return [String]()
      }
      return item.content.compactMap { content in
        content.type == "output_text" ? content.text : nil
      }
    }
    guard !textParts.isEmpty else {
      throw ExternalFormatterAdapterError.invalidResponseBody
    }
    return textParts.joined()
  }

  private struct RequestBody: Encodable {
    let model: String
    let instructions: String
    let input: String
    let store: Bool
  }

  private struct ResponseBody: Decodable {
    let status: String
    let output: [OutputItem]
  }

  private struct OutputItem: Decodable {
    let type: String
    let role: String?
    let content: [Content]

    private enum CodingKeys: CodingKey {
      case type
      case role
      case content
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      type = try container.decode(String.self, forKey: .type)
      role = try container.decodeIfPresent(String.self, forKey: .role)
      content =
        try container.decodeIfPresent(
          [Content].self,
          forKey: .content
        ) ?? []
    }
  }

  private struct Content: Decodable {
    let type: String
    let text: String?
  }
}

struct ChatCompletionsFormatterAdapter: Sendable {
  let endpointURL: URL
  let model: String
  let apiKey: String?
  let confirmation: ExternalEndpointConfirmation?
  let timeout: TimeInterval
  private let session: URLSession

  init(
    endpointURL: URL,
    model: String,
    apiKey: String? = nil,
    confirmation: ExternalEndpointConfirmation? = nil,
    timeout: TimeInterval = 60,
    session: URLSession = .shared
  ) {
    self.endpointURL = endpointURL
    self.model = model
    self.apiKey = apiKey
    self.confirmation = confirmation
    self.timeout = timeout
    self.session = session
  }

  func format(text: String, prompt: String) async throws -> String {
    try ExternalEndpointPolicy.requireAuthorization(
      for: endpointURL,
      purpose: .formatter,
      confirmation: confirmation
    )
    let body = RequestBody(
      model: model,
      messages: [
        Message(role: "system", content: prompt),
        Message(role: "user", content: text),
      ],
      stream: false
    )
    var request = try ExternalFormatterHTTPRequest.make(
      url: endpointURL,
      body: body,
      apiKey: apiKey
    )
    request.timeoutInterval = timeout
    let response: ResponseBody =
      try await ExternalFormatterHTTPResponse
      .perform(request, session: session)
    guard let choice = response.choices.first(where: { $0.index == 0 }),
      choice.finishReason == "stop",
      choice.message.role == "assistant",
      let content = choice.message.content
    else {
      throw ExternalFormatterAdapterError.invalidResponseBody
    }
    return content
  }

  private struct RequestBody: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool
  }

  private struct Message: Codable {
    let role: String
    let content: String
  }

  private struct ResponseBody: Decodable {
    let choices: [Choice]
  }

  private struct Choice: Decodable {
    let index: Int
    let finishReason: String
    let message: ResponseMessage

    private enum CodingKeys: String, CodingKey {
      case index
      case finishReason = "finish_reason"
      case message
    }
  }

  private struct ResponseMessage: Decodable {
    let role: String
    let content: String?
  }
}

private enum ExternalFormatterHTTPRequest {
  static func make<Body: Encodable>(
    url: URL,
    body: Body,
    apiKey: String?
  ) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey, !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONEncoder().encode(body)
    return request
  }
}

private enum ExternalFormatterHTTPResponse {
  static func perform<Response: Decodable>(
    _ request: URLRequest,
    session: URLSession
  ) async throws -> Response {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw ExternalFormatterAdapterError.invalidHTTPResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      throw ExternalFormatterAdapterError.unsuccessfulStatus(
        response.statusCode
      )
    }
    guard let body = try? JSONDecoder().decode(Response.self, from: data) else {
      throw ExternalFormatterAdapterError.invalidResponseBody
    }
    return body
  }
}
