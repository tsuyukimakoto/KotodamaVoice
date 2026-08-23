import Foundation
import KotodamaCore

@MainActor
final class URLSessionModelDownloader: ModelDownloading {
    func download(
        from url: URL,
        resumeData: Data?,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        let operation = ModelDownloadOperation(progress: progress)
        return try await operation.run(url: url, resumeData: resumeData)
    }
}

private final class ModelDownloadOperation: NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let progress: @MainActor @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var stableURL: URL?
    private var fileMoveError: Error?

    init(progress: @escaping @MainActor @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func run(url: URL, resumeData: Data?) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let session = URLSession(
                    configuration: .ephemeral,
                    delegate: self,
                    delegateQueue: nil
                )
                self.session = session
                let task = resumeData.map(session.downloadTask(withResumeData:))
                    ?? session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel { [weak self] resumeData in
                self?.complete(
                    .failure(ModelDownloadInterrupted(resumeData: resumeData))
                )
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(
            1,
            Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        )
        Task { @MainActor [progress] in
            progress(fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode)
        {
            lock.lock()
            fileMoveError = URLError(.badServerResponse)
            lock.unlock()
            return
        }

        do {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "KotodamaVoiceDownloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appending(
                path: UUID().uuidString,
                directoryHint: .notDirectory
            )
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            stableURL = destination
            lock.unlock()
        } catch {
            lock.lock()
            fileMoveError = error
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let stableURL = self.stableURL
        let fileMoveError = self.fileMoveError
        lock.unlock()

        if let fileMoveError {
            complete(.failure(fileMoveError))
        } else if let stableURL, error == nil {
            complete(.success(stableURL))
        } else if let error {
            let resumeData = (error as NSError).userInfo[
                NSURLSessionDownloadTaskResumeData
            ] as? Data
            if let resumeData {
                complete(
                    .failure(ModelDownloadInterrupted(resumeData: resumeData))
                )
            } else {
                complete(.failure(error))
            }
        } else {
            complete(.failure(URLError(.unknown)))
        }
    }

    private func complete(_ result: Result<URL, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let session = self.session
        self.session = nil
        task = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }
}
