import Foundation

func mapAppGroupDiagnosticFixture() throws -> Data {
    guard let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier:
            "group.jp.tsuyuki.KotodamaVoice"
    ) else {
        throw AppGroupDiagnosticFixtureError.containerUnavailable
    }
    let fixtureURL = containerURL
        .appending(path: "Diagnostics", directoryHint: .isDirectory)
        .appending(
            path: "worker-mmap.fixture",
            directoryHint: .notDirectory
        )
    return try Data(contentsOf: fixtureURL, options: .alwaysMapped)
}

private enum AppGroupDiagnosticFixtureError: Error {
    case containerUnavailable
}
