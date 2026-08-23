import KotodamaCore
import Testing
@testable import KotodamaVoice

@Test @MainActor
func embeddedWorkersReplyToDiagnosticEcho() async throws {
    let client = WorkerDiagnosticClient()

    for endpoint in WorkerEndpoint.allCases {
        let requestID = PipelineRequestID()
        let reply = try await client.echo(endpoint, requestID: requestID)

        #expect(reply.failure == nil)
        #expect(reply.requestID == requestID)
        #expect(reply.protocolVersion == KotodamaCore.protocolVersion)
    }
}
