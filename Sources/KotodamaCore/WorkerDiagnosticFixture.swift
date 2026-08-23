import Foundation

public enum WorkerDiagnosticFixture {
    public static func map(appGroupIdentifier: String) throws -> Data {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw WorkerDiagnosticFixtureError.containerUnavailable
        }
        let fixtureURL = containerURL
            .appending(path: "Diagnostics", directoryHint: .isDirectory)
            .appending(
                path: "worker-mmap.fixture",
                directoryHint: .notDirectory
            )
        return try Data(contentsOf: fixtureURL, options: .alwaysMapped)
    }
}

public enum WorkerDiagnosticFixtureError: Error, Equatable, Sendable {
    case containerUnavailable
}
