import AVFoundation
import Foundation
import KotodamaCore
import Testing
@testable import KotodamaVoice

@Test @MainActor
func temporaryAudioLeaseRemovesRequestDirectoryForEveryOutcome() throws {
    for _ in ["success", "failure", "cancel"] {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: "KotodamaVoiceAudioLeaseTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = TemporaryAudioStore(rootURL: rootURL)
        let requestID = PipelineRequestID()
        let lease = try store.createLease(
            requestID: requestID,
            buffer: try mono16kBuffer()
        )

        #expect(FileManager.default.fileExists(atPath: lease.directoryURL.path))
        #expect(lease.audioInput.sampleRate == 16_000)
        #expect(lease.audioInput.channelCount == 1)
        #expect(lease.audioInput.sampleCount == 16)

        lease.release()
        lease.release()
        #expect(!FileManager.default.fileExists(atPath: lease.directoryURL.path))
    }
}

private func mono16kBuffer() throws -> AVAudioPCMBuffer {
    let format = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
    )
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)
    )
    buffer.frameLength = 16
    return buffer
}
