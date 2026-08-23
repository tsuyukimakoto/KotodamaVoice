import Foundation
import KotodamaCore
import Testing
@testable import KotodamaVoice

@Suite(.serialized)
@MainActor
struct EmbeddedWorkerIntegrationTests {
    @Test
    func workersReplyToDiagnosticEcho() async throws {
        let client = WorkerDiagnosticClient()

        for endpoint in WorkerEndpoint.allCases {
            let requestID = PipelineRequestID()
            let reply = try await client.echo(endpoint, requestID: requestID)

            #expect(reply.failure == nil)
            #expect(reply.requestID == requestID)
            #expect(reply.protocolVersion == KotodamaCore.protocolVersion)
        }
    }

    @Test
    func workersRestartAfterForcedTermination() async throws {
        let client = WorkerDiagnosticClient()

        for endpoint in WorkerEndpoint.allCases {
            let firstReply = try await client.echo(endpoint)
            let firstProcess = try JSONDecoder().decode(
                DiagnosticProcessFixture.self,
                from: try #require(firstReply.payload)
            )

            #expect(kill(firstProcess.processIdentifier, SIGKILL) == 0)
            try await waitUntilProcessTerminates(
                firstProcess.processIdentifier
            )
            try await waitUntilConnectionIsDiscarded(
                by: client,
                endpoint: endpoint
            )

            let secondReply = try await client.echo(
                endpoint,
                timeout: .seconds(10)
            )
            let secondProcess = try JSONDecoder().decode(
                DiagnosticProcessFixture.self,
                from: try #require(secondReply.payload)
            )
            #expect(
                secondProcess.processIdentifier
                    != firstProcess.processIdentifier
            )
        }
    }
}

private struct DiagnosticProcessFixture: Decodable {
    let processIdentifier: pid_t
}

private func waitUntilProcessTerminates(_ processIdentifier: pid_t) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while kill(processIdentifier, 0) == 0 {
        guard ContinuousClock.now < deadline else {
            throw WorkerTerminationTestError.timedOut
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
private func waitUntilConnectionIsDiscarded(
    by client: WorkerDiagnosticClient,
    endpoint: WorkerEndpoint
) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while client.hasActiveConnection(to: endpoint) {
        guard ContinuousClock.now < deadline else {
            throw WorkerTerminationTestError.timedOut
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private enum WorkerTerminationTestError: Error {
    case timedOut
}
