import AVFoundation
import Foundation
import KotodamaCore

enum TemporaryAudioStoreError: Error {
    case unsupportedFormat
}

@MainActor
final class TemporaryAudioStore {
    private let rootURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.rootURL = rootURL ?? applicationSupport
            .appending(path: "KotodamaVoice", directoryHint: .isDirectory)
            .appending(path: "TemporaryAudio", directoryHint: .isDirectory)
    }

    func createLease(
        requestID: PipelineRequestID,
        buffer: AVAudioPCMBuffer
    ) throws -> TemporaryAudioLease {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.channelCount == 1,
              let samples = buffer.floatChannelData?[0]
        else {
            throw TemporaryAudioStoreError.unsupportedFormat
        }

        let requestDirectory = rootURL.appending(
            path: requestID.rawValue.uuidString,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: requestDirectory,
            withIntermediateDirectories: true
        )
        let fileURL = requestDirectory.appending(
            path: "audio-f32le.raw",
            directoryHint: .notDirectory
        )
        let data = Data(
            bytes: samples,
            count: Int(buffer.frameLength) * MemoryLayout<Float>.size
        )
        do {
            try data.write(to: fileURL, options: .atomic)
            let handle = try FileHandle(forReadingFrom: fileURL)
            let input = WorkerAudioInput(
                fileHandle: handle,
                sampleRate: buffer.format.sampleRate,
                channelCount: Int(buffer.format.channelCount),
                sampleCount: Int64(buffer.frameLength)
            )
            return TemporaryAudioLease(
                requestID: requestID,
                directoryURL: requestDirectory,
                audioInput: input,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: requestDirectory)
            throw error
        }
    }
}

@MainActor
final class TemporaryAudioLease {
    let requestID: PipelineRequestID
    let directoryURL: URL
    let audioInput: WorkerAudioInput

    private let fileManager: FileManager
    private var isReleased = false

    init(
        requestID: PipelineRequestID,
        directoryURL: URL,
        audioInput: WorkerAudioInput,
        fileManager: FileManager
    ) {
        self.requestID = requestID
        self.directoryURL = directoryURL
        self.audioInput = audioInput
        self.fileManager = fileManager
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        try? audioInput.fileHandle.close()
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try? fileManager.removeItem(at: directoryURL)
    }
}
