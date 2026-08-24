import Foundation

struct ExternalSpeechAudio: Sendable {
    let data: Data
    let fileName: String
    let contentType: String
}

enum ExternalSpeechAdapterError: Error, Equatable {
    case invalidHTTPResponse
    case unsuccessfulStatus(Int)
    case invalidResponseBody
}

struct OpenAIAudioTranscriptionsAdapter: Sendable {
    let endpointURL: URL
    let model: String
    let apiKey: String?
    let language: String?
    private let session: URLSession

    init(
        endpointURL: URL,
        model: String,
        apiKey: String? = nil,
        language: String? = nil,
        session: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
        self.model = model
        self.apiKey = apiKey
        self.language = language
        self.session = session
    }

    func transcribe(_ audio: ExternalSpeechAudio) async throws -> String {
        var form = MultipartFormData()
        form.appendFile(
            name: "file",
            fileName: audio.fileName,
            contentType: audio.contentType,
            data: audio.data
        )
        form.appendField(name: "model", value: model)
        if let language, !language.isEmpty {
            form.appendField(name: "language", value: language)
        }
        form.appendField(name: "response_format", value: "json")

        var request = form.request(url: endpointURL)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return try await SpeechTranscriptionHTTPResponse.perform(
            request,
            session: session
        )
    }
}

struct WhisperCppInferenceAdapter: Sendable {
    let endpointURL: URL
    let language: String?
    private let session: URLSession

    init(
        endpointURL: URL,
        language: String? = nil,
        session: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
        self.language = language
        self.session = session
    }

    func transcribe(_ audio: ExternalSpeechAudio) async throws -> String {
        var form = MultipartFormData()
        form.appendFile(
            name: "file",
            fileName: audio.fileName,
            contentType: audio.contentType,
            data: audio.data
        )
        if let language, !language.isEmpty {
            form.appendField(name: "language", value: language)
        }
        form.appendField(name: "response_format", value: "json")
        return try await SpeechTranscriptionHTTPResponse.perform(
            form.request(url: endpointURL),
            session: session
        )
    }
}

private enum SpeechTranscriptionHTTPResponse {
    private struct Body: Decodable {
        let text: String
    }

    static func perform(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> String {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ExternalSpeechAdapterError.invalidHTTPResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ExternalSpeechAdapterError.unsuccessfulStatus(
                response.statusCode
            )
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
            throw ExternalSpeechAdapterError.invalidResponseBody
        }
        return body.text
    }
}

private struct MultipartFormData {
    let boundary = "KotodamaVoice-\(UUID().uuidString)"
    private var body = Data()

    mutating func appendField(name: String, value: String) {
        appendBoundary()
        append("Content-Disposition: form-data; name=\"\(quoted(name))\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    mutating func appendFile(
        name: String,
        fileName: String,
        contentType: String,
        data: Data
    ) {
        appendBoundary()
        append(
            "Content-Disposition: form-data; name=\"\(quoted(name))\"; "
                + "filename=\"\(quoted(fileName))\"\r\n"
        )
        append("Content-Type: \(headerValue(contentType))\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    func request(url: URL) -> URLRequest {
        var completeBody = body
        completeBody.append(Data("--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = completeBody
        return request
    }

    private mutating func appendBoundary() {
        append("--\(boundary)\r\n")
    }

    private mutating func append(_ value: String) {
        body.append(Data(value.utf8))
    }

    private func quoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
    }

    private func headerValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
