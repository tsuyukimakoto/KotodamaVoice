import Foundation
import Network
import Testing
@testable import KotodamaVoice

@Test
func openAIAudioTranscriptionsAdapterUsesItsOwnMultipartContract() async throws {
    let server = try SpeechAdapterFixtureServer(
        responseBody: Data(#"{"text":"OpenAI文字起こし"}"#.utf8)
    )
    let adapter = OpenAIAudioTranscriptionsAdapter(
        endpointURL: server.url(path: "/v1/audio/transcriptions"),
        model: "gpt-4o-mini-transcribe",
        apiKey: "fixture-secret",
        language: "ja"
    )

    let text = try await adapter.transcribe(.fixture)
    let request = try #require(server.receivedRequest)

    #expect(text == "OpenAI文字起こし")
    #expect(request.requestLine == "POST /v1/audio/transcriptions HTTP/1.1")
    #expect(request.headers["authorization"] == "Bearer fixture-secret")
    #expect(request.headers["content-type"]?.hasPrefix("multipart/form-data; boundary=") == true)
    #expect(request.bodyString.contains("name=\"file\"; filename=\"recording.wav\""))
    #expect(request.bodyString.contains("Content-Type: audio/wav"))
    #expect(request.bodyString.contains("name=\"model\"\r\n\r\ngpt-4o-mini-transcribe"))
    #expect(request.bodyString.contains("name=\"language\"\r\n\r\nja"))
    #expect(request.bodyString.contains("name=\"response_format\"\r\n\r\njson"))
}

@Test
func whisperCppInferenceAdapterUsesThePinnedServerContract() async throws {
    let server = try SpeechAdapterFixtureServer(
        responseBody: Data(#"{"text":"whisper.cpp文字起こし"}"#.utf8)
    )
    let adapter = WhisperCppInferenceAdapter(
        endpointURL: server.url(path: "/inference"),
        language: "ja"
    )

    let text = try await adapter.transcribe(.fixture)
    let request = try #require(server.receivedRequest)

    #expect(text == "whisper.cpp文字起こし")
    #expect(request.requestLine == "POST /inference HTTP/1.1")
    #expect(request.headers["authorization"] == nil)
    #expect(request.bodyString.contains("name=\"file\"; filename=\"recording.wav\""))
    #expect(request.bodyString.contains("name=\"language\"\r\n\r\nja"))
    #expect(request.bodyString.contains("name=\"response_format\"\r\n\r\njson"))
    #expect(!request.bodyString.contains("name=\"model\""))
}

@Test(arguments: ExternalSpeechFixtureKind.allCases)
func externalSpeechAdaptersRejectAResponseWithoutText(
    kind: ExternalSpeechFixtureKind
) async throws {
    let server = try SpeechAdapterFixtureServer(
        responseBody: Data(#"{"result":"契約外"}"#.utf8)
    )

    await #expect(throws: ExternalSpeechAdapterError.invalidResponseBody) {
        switch kind {
        case .openAI:
            _ = try await OpenAIAudioTranscriptionsAdapter(
                endpointURL: server.url(path: "/v1/audio/transcriptions"),
                model: "gpt-4o-mini-transcribe"
            ).transcribe(.fixture)
        case .whisperCpp:
            _ = try await WhisperCppInferenceAdapter(
                endpointURL: server.url(path: "/inference")
            ).transcribe(.fixture)
        }
    }
}

enum ExternalSpeechFixtureKind: CaseIterable, Sendable {
    case openAI
    case whisperCpp
}

private extension ExternalSpeechAudio {
    static let fixture = ExternalSpeechAudio(
        data: Data("RIFF-fixture-audio".utf8),
        fileName: "recording.wav",
        contentType: "audio/wav"
    )
}

private struct ReceivedHTTPRequest: Sendable {
    let requestLine: String
    let headers: [String: String]
    let body: Data

    var bodyString: String {
        String(decoding: body, as: UTF8.self)
    }
}

private final class SpeechAdapterFixtureServer: @unchecked Sendable {
    private let responseBody: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SpeechAdapterFixtureServer")
    private let lock = NSLock()
    private var request: ReceivedHTTPRequest?

    init(responseBody: Data) throws {
        self.responseBody = responseBody
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(on: connection, accumulated: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success,
              listener.port != nil else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
    }

    deinit {
        listener.cancel()
    }

    var receivedRequest: ReceivedHTTPRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.start(queue: queue)
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var completeData = accumulated
            if let data { completeData.append(data) }
            if let request = Self.parseCompleteRequest(completeData) {
                self.store(request)
                self.respond(on: connection)
            } else if !isComplete, error == nil {
                self.receive(on: connection, accumulated: completeData)
            } else {
                connection.cancel()
            }
        }
    }

    private func store(_ request: ReceivedHTTPRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    private func respond(on connection: NWConnection) {
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
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseCompleteRequest(_ data: Data) -> ReceivedHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        guard let lengthText = headers["content-length"],
              let contentLength = Int(lengthText) else {
            return nil
        }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return ReceivedHTTPRequest(
            requestLine: requestLine,
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }
}
